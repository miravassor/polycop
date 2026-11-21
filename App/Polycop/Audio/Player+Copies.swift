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

/// Keeps at most one decoded copy of a recording AVFoundation cannot play
/// directly, keyed by the recording's path and resolved target identity.
final class CopyCache {
    private let folder: URL
    private(set) var kept: Player.KeptCopy?

    init(folder: URL) {
        self.folder = folder
    }

    /// The recording itself, the copy kept from an earlier playback, or a new
    /// one, which replaces it.
    func playable(_ recording: URL) async throws -> URL {
        let identity = Player.FileIdentity(of: recording)
        // Require a concrete identity before reusing a kept copy so failed
        // attribute reads never match one another as `nil == nil`.
        if let identity, let kept, kept.recording == recording,
            kept.identity == identity,
            FileManager.default.fileExists(atPath: kept.file.path(percentEncoded: false))
        {
            return kept.file
        }
        let file = try await Player.playableFile(for: recording, in: folder)
        guard file != recording else { return file }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: file)
            throw CancellationError()
        }
        discard()
        kept = Player.KeptCopy(recording: recording, identity: identity, file: file)
        return file
    }

    /// Deletes the kept copy, as at quit.
    func discard() {
        if let kept { try? FileManager.default.removeItem(at: kept.file) }
        kept = nil
    }
}

extension Player {
    /// Snapshot of a recording's resolved target attributes used to detect
    /// replacements at the same path even when the modification date is kept.
    struct FileIdentity: Equatable {
        let modified: Date
        let size: Int
        private let resource: any NSCopying & NSSecureCoding & NSObjectProtocol

        init?(of url: URL) {
            guard url.isFileURL else { return nil }
            // Resolve symlinks so edits to a symlink's target invalidate the copy,
            // and drop URL's resource cache, which persists until the next run loop turn.
            var fresh = url.resolvingSymlinksInPath()
            fresh.removeAllCachedResourceValues()
            guard
                let values = try? fresh.resourceValues(forKeys: [
                    .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
                    .fileResourceIdentifierKey,
                ]),
                values.isRegularFile == true,
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

    /// Opens a local recording as a self-contained asset. Rejects non-file
    /// URLs up front; AVFoundation's default policy already forbids
    /// local-to-remote references, and `.forbidAll` also forbids references to
    /// other local files outside the container.
    nonisolated static func asset(for url: URL, preciseTiming: Bool = false) throws -> AVURLAsset {
        guard url.isFileURL else { throw PlaybackError.unplayable(url) }
        var options: [String: Any] = [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ]
        if preciseTiming {
            options[AVURLAssetPreferPreciseDurationAndTimingKey] = true
        }
        return AVURLAsset(url: url, options: options)
    }

    /// AVURLAsset.load throws this policy rejection as a plain NSError that does
    /// not always bridge via `as? AVError`, so check domain and code directly.
    private nonisolated static func isForbiddenReference(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == AVFoundationErrorDomain
            && nsError.code == AVError.referenceForbiddenByReferencePolicy.rawValue
    }

    /// The recording itself when AVFoundation can play it, otherwise a decoded
    /// copy in `folder`. Asking AVFoundation rather than listing formats keeps
    /// this working on an older macOS, which may play fewer of them.
    @concurrent
    nonisolated static func playableFile(for recording: URL, in folder: URL = copies)
        async throws -> URL
    {
        try Task.checkCancellation()
        let asset = try Self.asset(for: recording)
        guard FileManager.default.fileExists(atPath: recording.path(percentEncoded: false)) else {
            throw PlaybackError.missing(recording)
        }
        do {
            if try await asset.load(.isPlayable) {
                try Task.checkCancellation()
                return recording
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.isForbiddenReference(error) {
                throw PlaybackError.unplayable(recording)
            }
        }
        try Task.checkCancellation()
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
