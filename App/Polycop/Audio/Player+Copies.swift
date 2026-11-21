// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation

extension Player {
    struct KeptCopy: Equatable {
        let recording: URL
        let modified: Date?
        let file: URL
    }

    /// Opens a recording as a self-contained asset. AVFoundation's default
    /// policy already forbids local-to-remote references; `.forbidAll` also
    /// forbids references to other local files outside the container.
    nonisolated static func asset(for url: URL, preciseTiming: Bool = false) -> AVURLAsset {
        var options: [String: Any] = [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ]
        if preciseTiming {
            options[AVURLAssetPreferPreciseDurationAndTimingKey] = true
        }
        return AVURLAsset(url: url, options: options)
    }

    /// The recording itself, the copy kept from an earlier playback, or a new
    /// one, which replaces it.
    func playable(_ recording: URL) async throws -> URL {
        let modified = try? recording.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        if let keptCopy, keptCopy.recording == recording, keptCopy.modified == modified,
            FileManager.default.fileExists(atPath: keptCopy.file.path(percentEncoded: false))
        {
            return keptCopy.file
        }
        let file = try await Player.playableFile(for: recording, in: copiesFolder)
        guard file != recording else { return file }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: file)
            throw CancellationError()
        }
        discardCopy()
        keptCopy = KeptCopy(recording: recording, modified: modified, file: file)
        return file
    }

    /// Deletes the kept copy, as at quit.
    func discardCopy() {
        if let keptCopy { try? FileManager.default.removeItem(at: keptCopy.file) }
        keptCopy = nil
    }

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
        let playable = try? await Self.asset(for: recording).load(.isPlayable)
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
