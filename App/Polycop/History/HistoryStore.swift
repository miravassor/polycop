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
        /// Records that could not be read, or the History folder's own name
        /// when it cannot be listed. Left exactly where they are, since a
        /// damaged file is the only copy of that transcript and may still be
        /// recoverable by hand.
        var damaged: [String] = []
        /// Records in a format this version does not know. Left where they are:
        /// rewriting one would drop what this version cannot read.
        var newer: [String] = []
    }

    /// Newest first. A record that fails to decode is skipped and left on
    /// disk, so one damaged file does not hide the rest. Its name is reported
    /// so the user is told a transcript is missing instead of losing it
    /// silently.
    static func all(in folder: URL = directory) -> Library {
        let path = folder.path(percentEncoded: false)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Library()
        } catch {
            return Library(damaged: [folder.lastPathComponent])
        }
        // `folders.json` lives in the same folder but is not an entry; isRecord
        // filters it out so it is never reported as a damaged record.
        let records = names.filter(isRecord).sorted()
        // Decoding is nearly all of a launch, and records do not depend on one
        // another, so they are decoded on every core at once.
        let read = OSAllocatedUnfairLock(
            initialState: [Result<Entry, UnreadableRecord>?](repeating: nil, count: records.count))
        DispatchQueue.concurrentPerform(iterations: records.count) { index in
            let result = record(folder.appending(path: records[index]))
            read.withLock { $0[index] = result }
        }
        var library = Library()
        for (name, result) in zip(records, read.withLock { $0 }) {
            switch result {
            case .success(let entry):
                library.entries.append(entry)
            case .failure(let failure):
                Log.persistence.error(
                    "a transcript record could not be read: \(failure.reason, privacy: .public)")
                if failure.needsNewerVersion {
                    library.newer.append(name)
                } else {
                    library.damaged.append(name)
                }
            case nil:
                library.damaged.append(name)
            }
        }
        library.entries.sort { $0.added > $1.added }
        return library
    }

    /// Why a record was not read, in words that hold none of its text: a record
    /// holds a lecture, and the log is read by whoever is sent it.
    struct UnreadableRecord: Error {
        let reason: String
        var needsNewerVersion = false
    }

    /// The entry a record holds, or why it was not read.
    static func record(
        _ file: URL, decoder: JSONDecoder = JSONDecoder()
    ) -> Result<Entry, UnreadableRecord> {
        func damaged(_ reason: String) -> Result<Entry, UnreadableRecord> {
            .failure(UnreadableRecord(reason: reason))
        }
        func newer(_ format: Int) -> Result<Entry, UnreadableRecord> {
            .failure(
                UnreadableRecord(
                    reason: "it requires format \(format), and this version knows \(knownFormat)",
                    needsNewerVersion: true))
        }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return damaged("the file cannot be read")
        }
        var entry: Entry
        do {
            entry = try decoder.decode(Entry.self, from: data)
        } catch {
            // A newer format need not decode as an `Entry`, so that alone does
            // not make a record damaged. Asked only now: reading every record
            // twice would slow each launch.
            if let format = try? decoder.decode(StoredFormat.self, from: data).requires,
                format > knownFormat
            {
                return newer(format)
            }
            return damaged(reason(error))
        }
        if let format = entry.requires, format > knownFormat { return newer(format) }
        guard entry.id == UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
            return damaged("its id differs from the file name")
        }
        entry.repair()
        guard entry.hasValidHistory else { return damaged("a time or a path is out of bounds") }
        return .success(entry)
    }

    private struct StoredFormat: Decodable {
        let requires: Int?
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
