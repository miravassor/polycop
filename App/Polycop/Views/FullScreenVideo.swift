// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import AppKit
import SwiftUI

/// The picture alone, filling the screen with the system's floating controls.
/// Space plays and pauses as on the page; Esc or a double click leaves.
struct FullScreenVideo: View {
    let model: AppModel

    var body: some View {
        FullScreenPlayer(player: model.player.player)
            .background(
                SpaceToPlay(isEnabled: !model.player.isPreparing, action: model.player.toggle)
            )
            .background(.black)
            .ignoresSafeArea()
    }

    /// A window made for the picture, on the screen of the window in front,
    /// which `VideoPresentation` takes full screen and closes after.
    static func window(for model: AppModel) -> NSWindow {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let window = NSWindow(
            contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: FullScreenVideo(model: model))
        return window
    }
}

/// The system player view with its floating controls: play, the timeline,
/// volume and the speeds the app offers.
private struct FullScreenPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
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

    func updateNSView(_ view: PlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.stopWatching()
    }

    /// Leaves full screen on Esc or a double click, as other players do.
    /// Watched rather than recognized: a click recognizer holds single clicks
    /// back, which the floating controls need at once.
    final class PlayerView: AVPlayerView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) {
                [weak self] event in
                guard let window = self?.window, event.window === window,
                    window.styleMask.contains(.fullScreen)
                else { return event }
                // 53 is the Esc key.
                let leaves =
                    event.type == .keyDown ? event.keyCode == 53 : event.clickCount == 2
                guard leaves else { return event }
                window.toggleFullScreen(nil)
                return event.type == .keyDown ? nil : event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
