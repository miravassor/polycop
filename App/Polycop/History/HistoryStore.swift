// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Entries as JSON files, one per transcript, in Application Support: a
/// recording transcribed twice has two. There is no separate index; the
/// directory listing is the library, as for glossaries and models.
nonisolated enum HistoryStore {
    static let directory = URL.applicationSupportDirectory.appending(path: "Polycop/History")
    /// The newest format of a record this version reads and rewrites. It rises
    /// only with a record that holds what an earlier version would lose or
    /// misread, and that record says so in `Entry.requires`.
    static let knownFormat = 1

    /// What the library holds, and what of it could not be read.
    struct Library {
        var entries: [Entry] = []
        var unavailable: [UnavailableRecord] = []
        /// Whether the History folder itself could not be listed.
        var isUnlisted = false
    }

    /// Newest first. A record that cannot be read is left on disk and reported,
    /// so one damaged file does not hide the rest, and the user is told rather
    /// than losing a transcript silently.
    static func all(in folder: URL = directory) -> Library {
        let path = folder.path(percentEncoded: false)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Library()
        } catch {
            return Library(isUnlisted: true)
        }
        // `folders.json` lives in the same folder but is not an entry; isRecord
        // filters it out so it is never reported as a damaged record.
        let records = names.filter(isRecord).sorted()
        // Decoding is nearly all of a launch, and records do not depend on one
        // another, so they are decoded on every core at once.
        let read = OSAllocatedUnfairLock(
            initialState: [Result<Entry, UnavailableRecord>?](repeating: nil, count: records.count))
        DispatchQueue.concurrentPerform(iterations: records.count) { index in
            let result = record(folder.appending(path: records[index]))
            read.withLock { $0[index] = result }
        }
        var library = Library()
        for (name, result) in zip(records, read.withLock { $0 }) {
            switch result {
            case .success(let entry):
                library.entries.append(entry)
            case .failure(let record):
                Log.persistence.error(
                    "a transcript record could not be read: \(record.reason, privacy: .public)")
                library.unavailable.append(record)
            case nil:
                library.unavailable.append(
                    UnavailableRecord(
                        file: folder.appending(path: name), reason: "it was not read"))
            }
        }
        library.entries.sort { $0.added > $1.added }
        return library
    }

    /// The entry a record holds, or why it cannot be read.
    static func record(
        _ file: URL, decoder: JSONDecoder = JSONDecoder()
    ) -> Result<Entry, UnavailableRecord> {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return .failure(UnavailableRecord(file: file, reason: "the file cannot be read"))
        }
        func summary() -> UnavailableRecord.Summary? {
            try? decoder.decode(UnavailableRecord.Summary.self, from: data)
        }
        func unavailable(
            _ reason: String, needsNewerVersion: Bool = false
        ) -> Result<Entry, UnavailableRecord> {
            let summary = summary()
            return .failure(
                UnavailableRecord(
                    file: file, reason: reason, needsNewerVersion: needsNewerVersion,
                    name: summary?.name, folderID: summary?.folderID, removed: summary?.removed))
        }
        func newer(_ format: Int) -> Result<Entry, UnavailableRecord> {
            unavailable(
                "it requires format \(format), and this version knows \(knownFormat)",
                needsNewerVersion: true)
        }
        var entry: Entry
        do {
            entry = try decoder.decode(Entry.self, from: data)
        } catch {
            // A newer format need not decode as an `Entry`, so that alone does
            // not make a record damaged. Asked only now: reading every record
            // twice would slow each launch.
            if let format = summary()?.requires, format > knownFormat { return newer(format) }
            return unavailable(reason(error))
        }
        if let format = entry.requires, format > knownFormat { return newer(format) }
        guard entry.id == UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
            return unavailable("its id differs from the file name")
        }
        entry.repair()
        guard entry.hasValidHistory else {
            return unavailable("a time or a path is out of bounds")
        }
        return .success(entry)
    }

    /// Which check a record failed.
    private static func reason(_ error: any Error) -> String {
        func path(_ keys: [any CodingKey]) -> String {
            keys.isEmpty ? "the top" : keys.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])) is missing"
        case DecodingError.typeMismatch(_, let context),
            DecodingError.valueNotFound(_, let context):
            return "\(path(context.codingPath)) has the wrong type"
        case DecodingError.dataCorrupted(let context):
            return "\(path(context.codingPath)) is not valid"
        default:
            return "the file is not a record"
        }
    }

    private static func isRecord(_ name: String) -> Bool {
        name.hasSuffix(".json") && UUID(uuidString: String(name.dropLast(5))) != nil
    }

    /// Claims the library for this process until it exits, so that a second
    /// copy of the app cannot write what it read at launch over this one's
    /// changes. False when another process holds it. A folder that cannot be
    /// opened is not refused here: reading it reports the problem.
    static func claim(_ folder: URL = directory) -> Bool {
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(folder.path(percentEncoded: false), O_RDONLY)
        guard descriptor >= 0 else { return true }
        // The descriptor stays open: the lock lasts until the process exits,
        // however it exits.
        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else { return true }
        let isHeld = errno == EWOULDBLOCK
        close(descriptor)
        return !isHeld
    }

    static func write(_ entry: Entry, in folder: URL = directory) throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(StoredEntry(entry: entry))
            .write(to: file(for: entry.id, in: folder), options: .atomic)
    }

    /// An entry as it goes to disk, with the version that wrote it: a fact about
    /// the file rather than the transcript. Nothing reads it yet. It is written
    /// from now on because a later repair, or a maintainer looking at a record,
    /// cannot get it back for the records written before.
    private struct StoredEntry: Encodable {
        let entry: Entry

        private enum CodingKeys: CodingKey {
            case writtenBy
        }

        func encode(to encoder: any Encoder) throws {
            try entry.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(Bundle.main.shortVersion, forKey: .writtenBy)
        }
    }

    static func delete(_ id: Entry.ID, in folder: URL = directory) throws {
        try LibrarySnapshots.remove(file(for: id, in: folder))
        do {
            try FileManager.default.removeItem(at: file(for: id, in: folder))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // An entry whose first write failed has no file to remove.
        }
    }

    /// Missing files mean no folders yet. Other read errors must block writes
    /// so creating a folder cannot overwrite unreadable existing names.
    static func folders(in directory: URL = directory) throws -> [TranscriptFolder] {
        do {
            let data = try Data(contentsOf: directory.appending(path: "folders.json"))
            let folders = try JSONDecoder().decode([TranscriptFolder].self, from: data)
            guard Set(folders.map(\.id)).count == folders.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return folders
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            Log.persistence.error("the list of folders could not be read")
            throw error
        }
    }

    static func writeFolders(_ folders: [TranscriptFolder], in directory: URL = directory) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(folders).write(
            to: directory.appending(path: "folders.json"), options: .atomic)
    }

    private static func file(for id: Entry.ID, in folder: URL) -> URL {
        folder.appending(path: id.uuidString + ".json")
    }
}
