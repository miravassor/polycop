// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Darwin

nonisolated enum PlaybackError: LocalizedError {
    case missing(URL)
    case unplayable(URL)

    private static func displayName(for recording: URL) -> String {
        let label = recording.lastPathComponent
        return (label.isEmpty || label == "/") ? recording.absoluteString : label
    }

    var errorDescription: String? {
        switch self {
        case .missing(let recording):
            String(
                localized:
                    "The recording is no longer where it was: \(Self.displayName(for: recording))"
            )
        case .unplayable(let recording):
            String(
                localized:
                    "The recording could not be played: \(Self.displayName(for: recording))"
            )
        }
    }
}

extension Player {
    /// Snapshot of a recording's resolved target attributes from POSIX `stat`,
    /// used to detect replacements at the same path even when mtime is kept.
    nonisolated struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        fileprivate init(
            device: dev_t, inode: ino_t, size: off_t,
            modifiedSeconds: Int, modifiedNanoseconds: Int
        ) {
            self.device = device
            self.inode = inode
            self.size = size
            self.modifiedSeconds = modifiedSeconds
            self.modifiedNanoseconds = modifiedNanoseconds
        }

        init?(of url: URL) {
            guard case .regular(let identity) = Player.probeFile(at: url) else { return nil }
            self = identity
        }
    }

    nonisolated struct KeptCopy: Equatable, Sendable {
        let recording: URL
        let identity: FileIdentity?
        let file: URL
    }

    /// Keeps at most one decoded copy of a recording AVFoundation cannot play
    /// directly, keyed by the recording's path and resolved target identity.
    final class CopyCache {
        private let folder: URL
        private(set) var kept: KeptCopy?
        private var generation = 0

        init(folder: URL) {
            self.folder = folder
        }

        /// The recording itself, the copy kept from an earlier playback, or a new
        /// one, which replaces it.
        func playable(_ recording: URL) async throws -> URL {
            try Task.checkCancellation()
            generation += 1
            let request = generation
            if let candidate = kept, candidate.recording == recording,
                let expected = candidate.identity
            {
                let valid = await Player.matchesKeptCopy(
                    candidate.file, recording: recording, expected: expected)
                guard !Task.isCancelled, request == generation else {
                    throw CancellationError()
                }
                if valid { return candidate.file }
            }
            let prepared = try await Player.preparePlayable(for: recording, in: folder)
            guard !Task.isCancelled, request == generation else {
                if prepared.file != recording {
                    try? FileManager.default.removeItem(at: prepared.file)
                }
                throw CancellationError()
            }
            if prepared.file == recording {
                if kept?.recording == recording { discard() }
                return recording
            }
            discard()
            kept = KeptCopy(recording: recording, identity: prepared.identity, file: prepared.file)
            return prepared.file
        }

        /// Deletes the kept copy, as at quit, and invalidates any in-flight decode.
        func discard() {
            generation += 1
            if let kept { try? FileManager.default.removeItem(at: kept.file) }
            kept = nil
        }
    }

    /// Result of POSIX `stat`, which follows symlinks atomically and bypasses
    /// `URL`'s cached resource values.
    private nonisolated enum FileProbe {
        case regular(FileIdentity)
        case notRegular
        case missing
        case unreadable
    }

    private nonisolated static func probeFile(at url: URL) -> FileProbe {
        guard url.isFileURL else { return .notRegular }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .unreadable }
            var info = Darwin.stat()
            if stat(path, &info) != 0 {
                let code = errno
                return (code == ENOENT || code == ENOTDIR) ? .missing : .unreadable
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { return .notRegular }
            return .regular(
                FileIdentity(
                    device: info.st_dev,
                    inode: info.st_ino,
                    size: info.st_size,
                    modifiedSeconds: info.st_mtimespec.tv_sec,
                    modifiedNanoseconds: info.st_mtimespec.tv_nsec))
        }
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

    /// Whether `error`, or an underlying error inside it, is AVFoundation's
    /// reference-policy rejection. `AVURLAsset.load` can throw this as a plain
    /// `NSError` that does not bridge via `as? AVError`, so inspect domain and
    /// code directly.
    nonisolated static func isForbiddenReference(_ error: any Error) -> Bool {
        isForbiddenReference(error as NSError, remainingDepth: 8)
    }

    private nonisolated static func isForbiddenReference(
        _ error: NSError, remainingDepth: Int
    ) -> Bool {
        if error.domain == AVFoundationErrorDomain,
            error.code == AVError.referenceForbiddenByReferencePolicy.rawValue
        {
            return true
        }
        guard remainingDepth > 0 else { return false }
        var children = error.underlyingErrors.map { $0 as NSError }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
            !children.contains(where: { $0 === underlying })
        {
            children.append(underlying)
        }
        return children.contains {
            isForbiddenReference($0, remainingDepth: remainingDepth - 1)
        }
    }

    @concurrent
    private nonisolated static func matchesKeptCopy(
        _ copy: URL, recording: URL, expected: FileIdentity
    ) async -> Bool {
        guard FileIdentity(of: recording) == expected else { return false }
        if case .regular = probeFile(at: copy) { return true }
        return false
    }

    @concurrent
    private nonisolated static func preparePlayable(for recording: URL, in folder: URL)
        async throws -> (file: URL, identity: FileIdentity?)
    {
        try Task.checkCancellation()
        let asset = try Self.asset(for: recording)
        let before: FileIdentity
        switch probeFile(at: recording) {
        case .regular(let identity): before = identity
        case .missing: throw PlaybackError.missing(recording)
        case .notRegular, .unreadable: throw PlaybackError.unplayable(recording)
        }
        do {
            if try await asset.load(.isPlayable) {
                try Task.checkCancellation()
                return (recording, nil)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isForbiddenReference(error) {
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
        // Only cache the identity when the source stayed identical across decode.
        let after = FileIdentity(of: recording)
        return (copy, before == after ? after : nil)
    }

    /// The recording itself when AVFoundation can play it, otherwise a decoded
    /// copy in `folder`. Asking AVFoundation rather than listing formats keeps
    /// this working on an older macOS, which may play fewer of them.
    @concurrent
    nonisolated static func playableFile(for recording: URL, in folder: URL = copies)
        async throws -> URL
    {
        try await preparePlayable(for: recording, in: folder).file
    }

    nonisolated static func sweep(in folder: URL = copies) {
        try? FileManager.default.removeItem(at: folder)
    }
}
