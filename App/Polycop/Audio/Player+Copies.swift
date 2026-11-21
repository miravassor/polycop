// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation

nonisolated enum PlaybackError: LocalizedError {
    case missing(URL)
    case unplayable(URL)

    var errorDescription: String? {
        switch self {
        case .missing(let recording):
            String(
                localized: "The recording is no longer where it was: \(recording.lastPathComponent)"
            )
        case .unplayable(let recording):
            String(localized: "The recording could not be played: \(recording.lastPathComponent)")
        }
    }
}

extension Player {
    /// Snapshot of a recording's file attributes used to detect replacements
    /// at the same path even when the modification date is preserved.
    struct FileIdentity: Equatable {
        let modified: Date
        let size: Int
        private let resource: any NSCopying & NSSecureCoding & NSObjectProtocol

        init?(of url: URL) {
            var fresh = url
            // URL caches resource values until the next run loop turn.
            fresh.removeAllCachedResourceValues()
            guard
                let values = try? fresh.resourceValues(forKeys: [
                    .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey,
                ]),
                let modified = values.contentModificationDate,
                let size = values.fileSize,
                let resource = values.fileResourceIdentifier
            else { return nil }
            self.modified = modified
            self.size = size
            self.resource = resource
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.modified == rhs.modified && lhs.size == rhs.size
                && lhs.resource.isEqual(rhs.resource)
        }
    }

    struct KeptCopy: Equatable {
        let recording: URL
        let identity: FileIdentity?
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
        let identity = FileIdentity(of: recording)
        // Require a concrete identity before reusing a kept copy so failed
        // attribute reads never match one another as `nil == nil`.
        if let identity, let keptCopy, keptCopy.recording == recording,
            keptCopy.identity == identity,
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
        keptCopy = KeptCopy(recording: recording, identity: identity, file: file)
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
