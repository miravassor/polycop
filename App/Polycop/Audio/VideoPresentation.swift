// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import AppKit
import Observation
import os

/// Where the picture of a video shows besides its page: floating in Picture
/// in Picture, which takes it off the page and gives the text its room, or
/// filling the screen.
@Observable
final class VideoPresentation: NSObject {
    private(set) var isInPictureInPicture = false {
        didSet { followOutsideControls() }
    }
    private(set) var isFullScreen = false {
        didSet { followOutsideControls() }
    }

    /// The layer Picture in Picture floats, which the main window keeps.
    @ObservationIgnored weak var pictureLayer: AVPlayerLayer?
    @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
    /// Waits for Picture in Picture to become possible, then starts it.
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// Stopped while the system was still floating it up.
    @ObservationIgnored private var stopsOnceStarted = false
    /// The window filling the screen with the picture, made by the page.
    @ObservationIgnored private var fullScreen: NSWindow?
    @ObservationIgnored private var fullScreenObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private let player: Player

    init(player: Player) {
        self.player = player
    }

    /// Picture in Picture as a switch, for the inspector's button. The system
    /// floats the picture a moment after it is turned on.
    var floatsPicture: Bool {
        get { isInPictureInPicture }
        set {
            if newValue {
                startPictureInPicture()
            } else {
                stopPictureInPicture()
            }
        }
    }

    /// Floats the picture above every window, on any screen.
    func startPictureInPicture() {
        guard let pictureLayer, let playing = player.player, pictureInPicture == nil else { return }
        stopsOnceStarted = false
        pictureLayer.player = playing
        let controller = AVPictureInPictureController(
            contentSource: .init(playerLayer: pictureLayer))
        controller.delegate = self
        pictureInPicture = controller
        starting = Task {
            // Possible once the controller has looked at the layer, a moment later.
            do {
                for _ in 0..<40 where !controller.isPictureInPicturePossible {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                return
            }
            // Stopped, or replaced, while its sleep had already ended.
            guard !Task.isCancelled, pictureInPicture === controller else { return }
            starting = nil
            guard controller.isPictureInPicturePossible else {
                pictureInPicture = nil
                pictureLayer.player = nil
                Log.playback.error("Picture in Picture was not possible")
                return
            }
            controller.startPictureInPicture()
        }
    }

    /// Brings the floating picture back to its page. Stopping a controller
    /// does nothing until its picture is up, so one still waiting never
    /// floats, and one floating up is stopped once it is.
    func stopPictureInPicture() {
        guard let pictureInPicture else { return }
        if let starting {
            starting.cancel()
            self.starting = nil
            self.pictureInPicture = nil
            pictureLayer?.player = nil
        } else if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else {
            stopsOnceStarted = true
        }
    }

    /// Fills the screen with the picture, in a window the page makes for it,
    /// closed again once the picture leaves full screen.
    func fillScreen(with make: () -> NSWindow) {
        guard fullScreen == nil else { return }
        stopPictureInPicture()
        let window = make()
        fullScreen = window
        let center = NotificationCenter.default
        fullScreenObservers = [
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { window.close() }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fullScreenClosed() }
            },
        ]
        isFullScreen = true
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    private func fullScreenClosed() {
        for observer in fullScreenObservers { NotificationCenter.default.removeObserver(observer) }
        fullScreenObservers = []
        fullScreen = nil
        isFullScreen = false
    }

    /// The system's controls of either can start playback.
    private func followOutsideControls() {
        player.followsOutsideControls = isInPictureInPicture || isFullScreen
    }

    /// Another recording has opened, or none: the floating picture is of the
    /// one that played, so it goes.
    func playerChanged(to player: AVPlayer?) {
        guard pictureInPicture != nil, pictureLayer?.player !== player else { return }
        stopPictureInPicture()
    }
}

extension VideoPresentation: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        isInPictureInPicture = true
        if stopsOnceStarted {
            stopsOnceStarted = false
            controller.stopPictureInPicture()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        if pictureInPicture === controller { pictureInPicture = nil }
        pictureLayer?.player = nil
        stopsOnceStarted = false
        isInPictureInPicture = false
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        if pictureInPicture === controller { pictureInPicture = nil }
        pictureLayer?.player = nil
        stopsOnceStarted = false
        Log.playback.error("Picture in Picture failed: \(error, privacy: .public)")
    }

    // The page shows the picture again by itself once it is back.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
