// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import AppKit
import SwiftUI

/// The picture of what plays in a window of its own: on a second screen, at
/// any size, or filling a screen. The system's floating controls drive it, and
/// Space plays and pauses as on the page.
struct VideoWindow: View {
    static let id = "video"
    let model: AppModel

    var body: some View {
        WindowPlayer(
            player: model.player.player, appeared: model.video.windowAppeared,
            leftFullScreen: model.video.windowLeftFullScreen
        )
        .background(SpaceToPlay(isEnabled: !model.player.isPreparing, action: model.player.toggle))
        .background(.black)
        .ignoresSafeArea()
        .onDisappear { model.video.windowClosed() }
    }
}

/// The system player view with its floating controls: play, the timeline,
/// volume and the speeds the app offers.
private struct WindowPlayer: NSViewRepresentable {
    let player: AVPlayer?
    let appeared: (NSWindow) -> Void
    let leftFullScreen: () -> Void

    func makeNSView(context: Context) -> FullPlayerView {
        let view = FullPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        // Live Text over a frame would take the double click.
        view.allowsVideoFrameAnalysis = false
        view.speeds = Player.speeds.map {
            AVPlaybackSpeed(
                rate: $0,
                localizedName: "\(Double($0).formatted(.number.precision(.fractionLength(0...2))))×"
            )
        }
        return view
    }

    func updateNSView(_ view: FullPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.appeared = appeared
        view.leftFullScreen = leftFullScreen
    }

    static func dismantleNSView(_ view: FullPlayerView, coordinator: ()) {
        view.stopWatching()
    }
}

/// A double click fills the screen or leaves it, and Esc leaves it, as in
/// other players.
private final class FullPlayerView: AVPlayerView {
    var appeared: (NSWindow) -> Void = { _ in }
    var leftFullScreen: () -> Void = {}
    private var monitor: Any?
    private var exit: (any NSObjectProtocol)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let doubleClick = NSClickGestureRecognizer(
            target: self, action: #selector(toggleFullScreen))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWatching()
        guard let window else { return }
        appeared(window)
        exit = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.leftFullScreen() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 is the Esc key.
            guard let window = self?.window, event.window === window, event.keyCode == 53,
                window.styleMask.contains(.fullScreen)
            else { return event }
            window.toggleFullScreen(nil)
            return nil
        }
    }

    func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let exit { NotificationCenter.default.removeObserver(exit) }
        monitor = nil
        exit = nil
    }

    @objc private func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
}
