// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AppKit
import SwiftUI

/// The picture of the recording playing, with no controls of its own: the
/// player bar below drives it, as it drives the sound. A click plays or pauses.
struct VideoView: NSViewRepresentable {
    let player: AVPlayer?
    let toggle: () -> Void

    func makeNSView(context: Context) -> PictureView { PictureView() }

    func updateNSView(_ view: PictureView, context: Context) {
        if view.picture.player !== player { view.picture.player = player }
        view.toggle = toggle
    }
}

/// A plain player layer rather than an AVPlayerView, whose Live Text overlay
/// takes every click on the picture.
final class PictureView: NSView {
    let picture = AVPlayerLayer()
    var toggle: () -> Void = {}

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

    override func mouseDown(with event: NSEvent) { toggle() }
}
