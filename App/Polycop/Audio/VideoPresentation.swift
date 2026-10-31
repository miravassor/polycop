// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import AppKit
import Observation
import os

/// Where the picture of a video shows besides its page: floating in Picture
/// in Picture, or in a window of its own, on a second screen or filling one.
/// Either takes the picture off the page, which gives the text its room.
@Observable
final class VideoPresentation: NSObject {
    private(set) var isInPictureInPicture = false {
        didSet { player.followsOutsideControls = isElsewhere }
    }
    private(set) var isInWindow = false {
        didSet { player.followsOutsideControls = isElsewhere }
    }
    var isElsewhere: Bool { isInPictureInPicture || isInWindow }

    /// The layer Picture in Picture floats, which the main window keeps.
    @ObservationIgnored weak var pictureLayer: AVPlayerLayer?
    @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
    @ObservationIgnored private weak var window: NSWindow?
    /// Asked for from a page; a window macOS restores at launch was not.
    @ObservationIgnored private var isWindowWanted = false
    @ObservationIgnored private var fillsScreenOnOpen = false
    /// Opened to fill the screen, so closed once it no longer does.
    @ObservationIgnored private var closesAfterFullScreen = false
    @ObservationIgnored private let player: Player

    init(player: Player) {
        self.player = player
    }

    /// Floats the picture above every window, on any screen.
    func startPictureInPicture() async {
        guard let pictureLayer, let playing = player.player, pictureInPicture == nil else { return }
        window?.close()
        pictureLayer.player = playing
        let controller = AVPictureInPictureController(
            contentSource: .init(playerLayer: pictureLayer))
        controller.delegate = self
        pictureInPicture = controller
        // Possible once the controller has looked at the layer, a moment later.
        for _ in 0..<40 where !controller.isPictureInPicturePossible {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard pictureInPicture === controller else { return }
        guard controller.isPictureInPicturePossible else {
            pictureInPicture = nil
            pictureLayer.player = nil
            Log.playback.error("Picture in Picture was not possible")
            return
        }
        controller.startPictureInPicture()
    }

    /// Brings the picture back to its page.
    func returnToPage() {
        pictureInPicture?.stopPictureInPicture()
        window?.close()
    }

    /// Opens the video window, or brings it forward, through `open`, the
    /// page's way of opening a window.
    func openWindow(with open: () -> Void) {
        pictureInPicture?.stopPictureInPicture()
        isWindowWanted = true
        open()
    }

    /// Fills the screen with the picture: in the video window, opened for it
    /// and closed again once the picture leaves full screen.
    func fillScreen(with open: () -> Void) {
        if let window {
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            return
        }
        fillsScreenOnOpen = true
        closesAfterFullScreen = true
        openWindow(with: open)
    }

    func windowAppeared(_ window: NSWindow) {
        guard window !== self.window else { return }
        guard isWindowWanted else {
            // Restored by macOS at launch, with nothing to show.
            window.close()
            return
        }
        self.window = window
        isInWindow = true
        if fillsScreenOnOpen {
            fillsScreenOnOpen = false
            // Once the window is on screen, which it is not yet.
            Task { window.toggleFullScreen(nil) }
        }
    }

    func windowLeftFullScreen() {
        if closesAfterFullScreen { window?.close() }
    }

    func windowClosed() {
        window = nil
        isWindowWanted = false
        fillsScreenOnOpen = false
        closesAfterFullScreen = false
        isInWindow = false
    }

    /// Another recording has opened, or none: the floating picture is of the
    /// one that played, so it goes.
    func playerChanged(to player: AVPlayer?) {
        guard let pictureInPicture, pictureLayer?.player !== player else { return }
        pictureInPicture.stopPictureInPicture()
    }
}

extension VideoPresentation: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        isInPictureInPicture = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        if pictureInPicture === controller { pictureInPicture = nil }
        pictureLayer?.player = nil
        isInPictureInPicture = false
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        if pictureInPicture === controller { pictureInPicture = nil }
        pictureLayer?.player = nil
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
