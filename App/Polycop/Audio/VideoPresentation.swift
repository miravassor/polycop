// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import AppKit
import Observation
import os

/// The surface of `AVPictureInPictureController` that `VideoPresentation`
/// drives, kept internal so tests can drive `isPictureInPicturePossible` via
/// KVO without opening a system Picture in Picture window.
protocol PictureInPictureController: AnyObject {
    var isPictureInPicturePossible: Bool { get }
    var isPictureInPictureActive: Bool { get }
    func observePossible(_ onPossible: @escaping @Sendable () -> Void) -> NSKeyValueObservation
    func startPictureInPicture()
    func stopPictureInPicture()
}

extension AVPictureInPictureController: PictureInPictureController {
    func observePossible(_ onPossible: @escaping @Sendable () -> Void) -> NSKeyValueObservation {
        VideoPresentation.observePossible(
            self, at: \.isPictureInPicturePossible, onPossible: onPossible)
    }
}

/// Where the picture of a video shows besides its page: floating in Picture
/// in Picture, which takes it off the page and gives the text its room, or
/// filling the screen.
@Observable
final class VideoPresentation: NSObject {
    /// Holds the KVO observation and bounded timeout for one pending start so
    /// every exit path tears both down together.
    private struct PendingStart {
        let attempt: Int
        let observation: NSKeyValueObservation
        let timeout: Task<Void, Never>

        func cancel() {
            observation.invalidate()
            timeout.cancel()
        }
    }

    private(set) var isInPictureInPicture = false {
        didSet { followOutsideControls() }
    }
    private(set) var isFullScreen = false {
        didSet { followOutsideControls() }
    }

    /// The layer Picture in Picture floats, which the main window keeps.
    @ObservationIgnored weak var pictureLayer: AVPlayerLayer?
    @ObservationIgnored private var pictureInPicture: (any PictureInPictureController)?
    /// Waits for Picture in Picture to become possible, then starts it.
    @ObservationIgnored private var pendingStart: PendingStart?
    /// Distinguishes each pending start so a queued KVO hop from an earlier
    /// attempt never acts on a later one.
    @ObservationIgnored private var startAttempt = 0
    /// Stopped while the system was still floating it up.
    @ObservationIgnored private var stopsOnceStarted = false
    /// The window filling the screen with the picture, made by the page.
    @ObservationIgnored private var fullScreen: NSWindow?
    @ObservationIgnored private var fullScreenObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private let player: Player
    @ObservationIgnored private let pictureInPictureTimeout: Duration
    @ObservationIgnored private let makePictureInPicture:
        @MainActor (AVPlayerLayer, VideoPresentation) -> (any PictureInPictureController)?

    /// `pictureInPictureTimeout` and `makePictureInPicture` exist for tests to
    /// drive `isPictureInPicturePossible` via KVO without floating a system
    /// Picture in Picture window.
    init(
        player: Player,
        pictureInPictureTimeout: Duration = .seconds(2),
        makePictureInPicture:
            @escaping @MainActor (AVPlayerLayer, VideoPresentation) ->
            (any PictureInPictureController)? = VideoPresentation.makeSystemPictureInPicture
    ) {
        self.player = player
        self.pictureInPictureTimeout = pictureInPictureTimeout
        self.makePictureInPicture = makePictureInPicture
    }

    isolated deinit {
        cancelPendingStart()
    }

    private static func makeSystemPictureInPicture(
        layer: AVPlayerLayer, delegate: VideoPresentation
    ) -> (any PictureInPictureController)? {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        controller.delegate = delegate
        return controller
    }

    /// Watches a KVO flag until it becomes true. KVO may deliver notifications
    /// on any thread, so `onPossible` runs outside the main actor.
    nonisolated static func observePossible<Observed: NSObject>(
        _ observed: Observed,
        at keyPath: KeyPath<Observed, Bool>,
        onPossible: @escaping @Sendable () -> Void
    ) -> NSKeyValueObservation {
        observed.observe(keyPath, options: [.initial, .new]) { _, change in
            if change.newValue == true { onPossible() }
        }
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
        guard let controller = makePictureInPicture(pictureLayer, self) else {
            pictureLayer.player = nil
            Log.playback.error("Picture in Picture is not supported")
            return
        }
        pictureInPicture = controller
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }
        // Possible once the controller has looked at the layer; KVO may deliver
        // on any thread, so hop back to the main actor and bound the wait.
        startAttempt += 1
        let attempt = startAttempt
        let timeoutDuration = pictureInPictureTimeout
        let timeout = Task { [weak self] in
            do {
                try await Task.sleep(for: timeoutDuration)
            } catch {
                return
            }
            self?.startTimedOut(attempt: attempt)
        }
        let observation = controller.observePossible { [weak self] in
            Task { @MainActor [weak self] in
                self?.pictureInPictureBecamePossible(attempt: attempt)
            }
        }
        pendingStart = PendingStart(attempt: attempt, observation: observation, timeout: timeout)
    }

    /// Brings the floating picture back to its page. Stopping a controller
    /// does nothing until its picture is up, so one still waiting never
    /// floats, and one floating up is stopped once it is.
    func stopPictureInPicture() {
        guard let pictureInPicture else { return }
        if pendingStart != nil {
            cancelPendingStart()
            self.pictureInPicture = nil
            pictureLayer?.player = nil
        } else if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else {
            stopsOnceStarted = true
        }
    }

    private func pictureInPictureBecamePossible(attempt: Int) {
        guard pendingStart?.attempt == attempt,
            let pictureInPicture,
            pictureInPicture.isPictureInPicturePossible
        else { return }
        cancelPendingStart()
        pictureInPicture.startPictureInPicture()
    }

    private func startTimedOut(attempt: Int) {
        guard pendingStart?.attempt == attempt else { return }
        cancelPendingStart()
        if let pictureInPicture, pictureInPicture.isPictureInPicturePossible {
            pictureInPicture.startPictureInPicture()
            return
        }
        pictureInPicture = nil
        pictureLayer?.player = nil
        Log.playback.error("Picture in Picture was not possible")
    }

    private func cancelPendingStart() {
        pendingStart?.cancel()
        pendingStart = nil
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
