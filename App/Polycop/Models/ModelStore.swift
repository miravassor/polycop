// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import os

/// Where downloaded models live, and how their contents are proven.
nonisolated enum ModelStore {
    /// A plain folder name rather than the bundle identifier, beside the
    /// library, so gigabytes of downloads never depend on the identifier.
    static let directory = URL.applicationSupportDirectory.appending(path: "Polycop/Models")

    static func location(of model: Model, in folder: URL = directory) -> URL {
        folder.appending(path: model.id)
    }

    /// Where an interrupted download of `model` keeps what it needs to
    /// continue. Named by hash, so a catalogue update that pins a new file
    /// under the same id never resumes the old one.
    static func resumeFile(of model: Model, in folder: URL = directory) -> URL {
        folder.appending(path: model.sha256 + ".resume")
    }

    /// Where a transfer of `model` that arrived whole waits for its check.
    /// Named by hash, as resume data is; the sweep keeps it while the model
    /// is not installed.
    static func receivedFile(of model: Model, in folder: URL = directory) -> URL {
        folder.appending(path: model.sha256 + ".part")
    }

    /// Installed means present at the expected size. Listing the library must
    /// stay instant, so the contents are proven elsewhere, when the file
    /// arrives and again before each native load.
    static func isInstalled(_ model: Model, in folder: URL = directory) -> Bool {
        let file = location(of: model, in: folder)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return Int64(size) == model.bytes
    }

    /// Left free on top of a model, so a download never fills the Mac to the
    /// last byte, which stops other programs and the system itself.
    static let spaceMargin: Int64 = 1_000_000_000

    /// Reads the capacity the system offers for something the user asked to
    /// keep, which counts what it would clear (caches, purgeable files) rather
    /// than only what is empty now. Nil when it cannot be read, so an odd
    /// volume never blocks a download.
    static func availableCapacity(of folder: URL) -> Int64? {
        let values = try? folder.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// What is needed and what is free, when the folder's volume cannot take
    /// `bytes` and the margin; nil when it can, or when that cannot be known.
    /// A file that waits in the folder before its rename needs one copy only.
    static func shortfall(
        forBytes bytes: Int64, in folder: URL, available: @Sendable (URL) -> Int64?
    ) -> (needed: Int64, available: Int64)? {
        let needed = bytes + spaceMargin
        guard let free = available(folder), free < needed else { return nil }
        return (needed, free)
    }

    /// The same words for a download and an import that are refused.
    static func notEnoughSpaceMessage(needed: Int64, available: Int64) -> String {
        let needed = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        return String(
            localized:
                "Not enough disk space for this model: \(needed) are needed, including 1 GB of margin, and \(available) are free. Free some space and try again."
        )
    }

    static func installed() -> [Model] {
        ModelCatalog.all.filter { isInstalled($0) }
    }

    /// A model file in the store that the catalogue does not claim, such as one
    /// copied there by hand. Imports accept only catalogue files, so the app
    /// never loads it; the model list shows it as unverified, to delete. It is
    /// a separate type rather than a catalogue entry with invented fields.
    struct Imported: Identifiable, Equatable, Sendable {
        let id: String
        let bytes: Int64
        var name: String { (id as NSString).deletingPathExtension }
    }

    /// Anything in the store that the catalogue does not claim. The folder is
    /// the whole record, so deleting the file is the only way to remove it.
    static func imported(in folder: URL = directory) -> [Imported] {
        let manager = FileManager.default
        let path = folder.path(percentEncoded: false)
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return [] }

        let catalogued = Set(ModelCatalog.files.map { $0.id.lowercased() })
        return
            names
            .filter {
                ($0.hasSuffix(".bin") || $0.hasSuffix(".gguf"))
                    && !catalogued.contains($0.lowercased())
            }
            .compactMap { name in
                let size =
                    (try? folder.appending(path: name)
                        .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return size > 0 ? Imported(id: name, bytes: Int64(size)) : nil
            }
            .sorted { $0.id < $1.id }
    }

    enum ImportError: LocalizedError, Equatable {
        case unrecognized
        case damaged(Model)
        case notEnoughSpace(needed: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .notEnoughSpace(let needed, let available):
                notEnoughSpaceMessage(needed: needed, available: available)
            case .unrecognized:
                String(
                    localized:
                        "This file does not match a supported model. Import an unchanged model from the catalogue, or download it in the app."
                )
            case .damaged(let model):
                String(
                    localized:
                        "The file of \(model.name) is not the one that was installed. Delete it and download it again."
                )
            }
        }
    }

    /// Verifies the file about to enter a native parser, including after a reload.
    static func verify(_ model: Model, at file: URL) async throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard file.isFileURL, values.isRegularFile == true,
            values.fileSize.map(Int64.init) == model.bytes,
            try await sha256(of: file) == model.sha256
        else {
            Log.models.error("the installed \(model.id, privacy: .public) does not match its hash")
            throw ImportError.damaged(model)
        }
    }

    /// Puts a finished file in place of whatever the store holds under that
    /// name, without a moment where neither is there. Removing first would lose
    /// a working model if the move then failed.
    static func publish(_ received: URL, as destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try manager.replaceItemAt(destination, withItemAt: received)
        } else {
            try manager.moveItem(at: received, to: destination)
        }
    }

    /// Verifies the copied bytes before publishing or passing them to whisper.cpp.
    /// The copy runs on a queue of its own: gigabytes from a slow disk would
    /// hold a thread of the Swift concurrency pool for minutes. A stop is read
    /// between blocks.
    /// `availableCapacity` is for tests, which cannot fill a disk.
    static func install(
        _ source: URL, in folder: URL = directory, catalogue: [Model] = ModelCatalog.files,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = ModelStore.availableCapacity(of:)
    ) async throws -> Model {
        try Task.checkCancellation()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await copyingQueue.run {
                try copy(
                    source, into: folder, catalogue: catalogue, until: cancelled,
                    availableCapacity: availableCapacity)
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private static let copyingQueue = DispatchQueue(
        label: "io.github.miravassor.Polycop.importing", qos: .userInitiated)

    private static func copy(
        _ source: URL, into folder: URL, catalogue: [Model],
        until cancelled: OSAllocatedUnfairLock<Bool>,
        availableCapacity: @Sendable (URL) -> Int64?
    ) throws -> Model {
        func checkCancellation() throws {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
        }
        guard source.isFileURL else { throw ImportError.unrecognized }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw ImportError.unrecognized
        }
        let candidates = catalogue.filter { $0.bytes == Int64(size) }
        guard !candidates.isEmpty else { throw ImportError.unrecognized }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Refused before the first byte is copied, not after gigabytes.
        if let short = shortfall(forBytes: Int64(size), in: folder, available: availableCapacity) {
            throw ImportError.notEnoughSpace(needed: short.needed, available: short.available)
        }
        let partial = folder.appending(path: UUID().uuidString + ".part")
        defer { try? manager.removeItem(at: partial) }
        guard
            manager.createFile(
                atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        var hasher = SHA256()
        var copied = 0
        while let block = try input.read(upToCount: 1 << 20), !block.isEmpty {
            try checkCancellation()
            copied += block.count
            guard copied <= size else { throw ImportError.unrecognized }
            hasher.update(data: block)
            try output.write(contentsOf: block)
        }
        try output.close()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard copied == size, let model = candidates.first(where: { $0.sha256 == digest }) else {
            throw ImportError.unrecognized
        }
        try checkCancellation()
        try publish(partial, as: folder.appending(path: model.id))
        return model
    }

    static func remove(imported: Imported, in folder: URL = directory) throws {
        try FileManager.default.removeItem(at: folder.appending(path: imported.id))
    }

    private static let hashingQueue = DispatchQueue(
        label: "io.github.miravassor.Polycop.hashing", qos: .userInitiated)

    /// Hashing gigabytes takes seconds. A nonisolated async function inherits
    /// the actor that called it, so without this hop the check ran on the main
    /// actor and froze the window at the end of every download. A stop is read
    /// between blocks, so quitting does not wait for the whole file.
    static func sha256(of file: URL) async throws -> String {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await hashingQueue.run { try FileDigest.sha256(of: file, until: cancelled) }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    static func remove(_ model: Model, in folder: URL = directory) throws {
        try FileManager.default.removeItem(at: location(of: model, in: folder))
        // An interrupted transfer of the same model would outlive it otherwise.
        try? FileManager.default.removeItem(at: resumeFile(of: model, in: folder))
        try? FileManager.default.removeItem(at: receivedFile(of: model, in: folder))
    }

    /// Removes what interrupted work leaves behind: files received or copied
    /// but never published, and resume data for a model that has since
    /// finished downloading or for a file the catalogue no longer pins.
    /// Resume data named by catalogue id, as 0.3.2 and earlier named it, is
    /// renamed by hash while the catalogue pins the same file under that id.
    static func sweep(in folder: URL = directory, catalogue: [Model] = ModelCatalog.files) {
        let manager = FileManager.default
        let path = folder.path(percentEncoded: false)
        guard let entries = try? manager.contentsOfDirectory(atPath: path) else { return }

        for name in entries where name.hasSuffix(".resume") || name.hasSuffix(".part") {
            let file = folder.appending(path: name)
            let owner = (name as NSString).deletingPathExtension
            // Only what Polycop writes goes: the folder may be a link to one
            // that other programs use too.
            let isFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            guard isFile == true else { continue }
            if let model = catalogue.first(where: { $0.sha256 == owner }) {
                if isInstalled(model, in: folder) { try? manager.removeItem(at: file) }
                continue
            }
            // The move fails, and the file goes, when resume data named by
            // hash is already there.
            if name.hasSuffix(".resume"),
                let model = catalogue.first(where: { $0.id == owner }),
                !isInstalled(model, in: folder),
                (try? manager.moveItem(at: file, to: resumeFile(of: model, in: folder))) != nil
            {
                continue
            }
            let isDigest = owner.count == 64 && owner.allSatisfy(\.isHexDigit)
            guard
                isDigest || UUID(uuidString: owner) != nil
                    || catalogue.contains(where: { $0.id == owner })
            else { continue }
            try? manager.removeItem(at: file)
        }
    }
}
