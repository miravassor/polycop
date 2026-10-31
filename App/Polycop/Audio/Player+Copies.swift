// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation

extension Player {
    /// The recording itself when AVFoundation can play it, otherwise a decoded
    /// copy in `folder`. Asking AVFoundation rather than listing formats keeps
    /// this working on an older macOS, which may play fewer of them.
    @concurrent
    nonisolated static func playableFile(for recording: URL, in folder: URL = copies)
        async throws -> URL
    {
        try Task.checkCancellation()
        guard recording.isFileURL else { throw PlaybackError.unplayable(recording) }
        guard FileManager.default.fileExists(atPath: recording.path(percentEncoded: false)) else {
            throw PlaybackError.missing(recording)
        }
        let playable = try? await AVURLAsset(url: recording).load(.isPlayable)
        try Task.checkCancellation()
        if playable == true {
            return recording
        }
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appending(path: UUID().uuidString + ".wav")
        do {
            try await AudioDecoder.writePlayableCopy(of: recording, to: copy)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
        return copy
    }

    nonisolated static func sweep(in folder: URL = copies) {
        try? FileManager.default.removeItem(at: folder)
    }
}
