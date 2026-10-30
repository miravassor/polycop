// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import SwiftUI

/// The picture of the recording playing, with no controls of its own: the
/// player bar below drives it, as it drives the sound. A click plays or pauses.
struct VideoView: NSViewRepresentable {
    let player: AVPlayer?
    let toggle: () -> Void

    func makeNSView(context: Context) -> PictureView {
        let view = PictureView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.setAccessibilityLabel(String(localized: "Video"))
        return view
    }

    func updateNSView(_ view: PictureView, context: Context) {
        if view.player !== player { view.player = player }
        view.toggle = toggle
    }
}

final class PictureView: AVPlayerView {
    var toggle: () -> Void = {}

    // Never the key view, so Space and the shortcuts keep reaching the player.
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) { toggle() }
}
