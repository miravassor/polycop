// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import SwiftUI

/// The picture of a video recording, which the reader can hide to keep the
/// sound alone. Only these two views read that setting, and only a video has
/// them: a view that reads a setting is drawn again at each correction handed
/// over, which the player card of every transcript should not be.
struct EntryVideo: View {
    let model: AppModel
    let id: Entry.ID
    let source: URL
    let picture: CGSize
    /// Where the reader left off, played from when nothing is open yet.
    let resume: TimeInterval
    /// The tallest the picture may be: less under the transcript than beside it.
    let maxHeight: CGFloat
    @AppStorage(EntryVideo.shownKey) private var isShown = true
    @State private var width: CGFloat = 0

    static let shownKey = "showsVideo"

    var body: some View {
        if isShown {
            // Sized from the width, since the transcript above takes every
            // point of height it is offered.
            VideoView(player: shownPlayer, toggle: togglePlayback)
                .frame(width: shownWidth, height: shownWidth * picture.height / picture.width)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    width = $0
                }
        }
    }

    /// The whole width, unless the picture would then be taller than allowed.
    private var shownWidth: CGFloat {
        max(0, min(width, maxHeight * picture.width / picture.height))
    }

    /// The player while it holds this recording; another one's picture, or
    /// none, leaves the frame black.
    private var shownPlayer: AVPlayer? {
        model.player.recording == source ? model.player.player : nil
    }

    private func togglePlayback() {
        if shownPlayer != nil {
            model.player.toggle()
        } else {
            model.replay(id, from: resume, leadIn: 0)
        }
    }
}

/// Shows or hides the picture, beside the player card's title.
struct VideoToggle: View {
    @AppStorage(EntryVideo.shownKey) private var isShown = true

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: isShown ? "video.slash" : "video")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .iconControl()
        .accessibilityLabel(isShown ? "Hide Video" : "Show Video")
        .help(isShown ? "Keep the sound only" : "Show the video")
    }
}
