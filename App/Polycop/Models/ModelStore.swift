// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import os

/// Where downloaded models live, and how their contents are proven.
nonisolated enum ModelStore {
    /// A plain folder name rather than the bundle identifier, beside the
    /// library, so gigabytes of downloads never depend on the identifier.
    static let directory = URL.applicationSupportDirectory.appending(path: "Polycop/Models")

    static func location(of model: Model) -> URL {
        directory.appending(path: model.id)
    }

    /// Installed means present at the expected size. Listing the library must
    /// stay instant, so the contents are proven elsewhere, when the file
    /// arrives and again before each native load.
    static func isInstalled(_ model: Model) -> Bool {
        let file = location(of: model)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return Int64(size) == model.bytes
    }

    static func installed() -> [Model] {
        ModelCatalog.all.filter(isInstalled)
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
    static func imported() -> [Imported] {
        let manager = FileManager.default
        let path = directory.path(percentEncoded: false)
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
                    (try? directory.appending(path: name)
                        .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return size > 0 ? Imported(id: name, bytes: Int64(size)) : nil
            }
            .sorted { $0.id < $1.id }
    }

    enum ImportError: LocalizedError, Equatable {
        case unrecognized
        case damaged(Model)

        var errorDescription: String? {
            switch self {
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
    static func install(
        _ source: URL, in folder: URL = directory, catalogue: [Model] = ModelCatalog.files
    ) async throws -> Model {
        try Task.checkCancellation()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await copyingQueue.run {
                try copy(source, into: folder, catalogue: catalogue, until: cancelled)
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private static let copyingQueue = DispatchQueue(
        label: "io.github.miravassor.Polycop.importing", qos: .userInitiated)

    private static func copy(
        _ source: URL, into folder: URL, catalogue: [Model],
        until cancelled: OSAllocatedUnfairLock<Bool>
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

    static func remove(imported: Imported) throws {
        try FileManager.default.removeItem(at: directory.appending(path: imported.id))
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

    static func remove(_ model: Model) throws {
        try FileManager.default.removeItem(at: location(of: model))
        // An interrupted transfer of the same model would outlive it otherwise.
        try? FileManager.default.removeItem(at: directory.appending(path: model.id + ".resume"))
    }

    /// Removes what interrupted work leaves behind: files received or copied
    /// but never published, and resume data for a model that has since
    /// finished downloading or that the catalogue no longer offers.
    static func sweep(in folder: URL = directory) {
        let manager = FileManager.default
        let path = folder.path(percentEncoded: false)
        guard let entries = try? manager.contentsOfDirectory(atPath: path) else { return }

        let offered = Set(ModelCatalog.files.map(\.id))
        for name in entries where name.hasSuffix(".resume") || name.hasSuffix(".part") {
            let owner = (name as NSString).deletingPathExtension
            let finished = manager.fileExists(
                atPath: folder.appending(path: owner).path(percentEncoded: false))
            if finished || !offered.contains(owner) {
                try? manager.removeItem(at: folder.appending(path: name))
            }
        }
    }
}
