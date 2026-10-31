// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AppKit
import SwiftUI

/// The picture of the recording playing, with no controls of its own: the
/// player bar below drives it, as it drives the sound. A click plays or
/// pauses, a double click fills the screen.
struct VideoView: NSViewRepresentable {
    let player: AVPlayer?
    let toggle: () -> Void
    let fillScreen: () -> Void

    func makeNSView(context: Context) -> PictureView { PictureView() }

    func updateNSView(_ view: PictureView, context: Context) {
        if view.picture.player !== player { view.picture.player = player }
        view.toggle = toggle
        view.fillScreen = fillScreen
    }
}

/// A plain player layer rather than an AVPlayerView, whose Live Text overlay
/// takes every click on the picture.
final class PictureView: NSView {
    let picture = AVPlayerLayer()
    var toggle: () -> Void = {}
    var fillScreen: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        picture.videoGravity = .resizeAspect
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Video"))
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { picture }

    // Never the key view, so Space and the shortcuts keep reaching the player.
    override var acceptsFirstResponder: Bool { false }

    // The second click of a double click plays or pauses again, so the
    // picture fills the screen as it was, playing or paused.
    override func mouseDown(with event: NSEvent) {
        toggle()
        if event.clickCount == 2 { fillScreen() }
    }
}

/// The layer Picture in Picture floats, unseen in the main window whatever page
/// shows: macOS ends Picture in Picture only while that layer is in a window,
/// and starts it only from one with a size.
struct PictureInPictureSource: View {
    let model: AppModel

    var body: some View {
        SourceLayer(video: model.video)
            .frame(width: 2, height: 2)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: model.player.player) { _, player in model.video.playerChanged(to: player)
            }
    }

    private struct SourceLayer: NSViewRepresentable {
        let video: VideoPresentation

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            let layer = AVPlayerLayer()
            view.layer = layer
            view.wantsLayer = true
            video.pictureLayer = layer
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {}
    }
}
