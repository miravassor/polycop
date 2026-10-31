// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation

extension Player {
    /// Opens a recording paused where the reader left it, so that a video
    /// shows its picture before anything plays.
    func prepare(_ recording: URL, at time: TimeInterval) {
        guard !isOpen, !isPreparing else { return }
        play(recording, from: time)
        pause()
    }

    /// The size of the picture AVFoundation draws for a recording, or nil for
    /// one it has none for. A video it cannot play, such as WebM, plays from a
    /// copy with the sound only.
    @concurrent
    nonisolated static func pictureSize(of recording: URL) async -> CGSize? {
        let asset = AVURLAsset(url: recording)
        guard (try? await asset.load(.isPlayable)) == true,
            let track = try? await asset.loadTracks(withMediaType: .video).first,
            let geometry = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        // A phone video filmed upright is stored on its side, with a rotation.
        let shown = CGRect(origin: .zero, size: geometry.0).applying(geometry.1).size
        guard shown.width > 0, shown.height > 0 else { return nil }
        return CGSize(width: abs(shown.width), height: abs(shown.height))
    }
}
