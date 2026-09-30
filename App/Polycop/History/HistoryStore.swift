// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Entries as JSON files, one per recording, in Application Support. There is
/// no separate index; the directory listing is the library, as for glossaries
/// and models.
nonisolated enum HistoryStore {
    static let directory = URL.applicationSupportDirectory.appending(path: "Polycop/History")

    /// What the library holds, and what of it could not be read.
    struct Library {
        var entries: [Entry] = []
        /// Records that could not be read. Left exactly where they are, since
        /// a damaged file is the only copy of that transcript and may still
        /// be recoverable by hand.
        var damaged: [String] = []
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
        let decoder = JSONDecoder()
        var library = Library()
        // `folders.json` lives in the same folder but is not an entry; isRecord
        // filters it out so it is never reported as a damaged record.
        for name in names where isRecord(name) {
            if let entry = try? decoder.decode(
                Entry.self, from: Data(contentsOf: folder.appending(path: name))),
                entry.id == UUID(uuidString: String(name.dropLast(5))), entry.hasValidHistory
            {
                library.entries.append(entry)
            } else {
                Log.persistence.error("a transcript record could not be read")
                library.damaged.append(name)
            }
        }
        library.entries.sort { $0.added > $1.added }
        return library
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
        try JSONEncoder().encode(entry).write(to: file(for: entry.id, in: folder), options: .atomic)
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

nonisolated extension Entry {
    /// Whether every numeric field is finite and within plausible bounds;
    /// used to reject a record too corrupted to display safely.
    var hasValidHistory: Bool {
        let ceiling = AudioDecoder.longestRecording + 60
        func time(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= ceiling }
        func paragraphsAreValid(_ values: [Transcript.Paragraph]) -> Bool {
            values.allSatisfy { $0.start >= 0 && Double($0.start) <= ceiling * 1000 }
                && zip(values, values.dropFirst()).allSatisfy { $0.start <= $1.start }
        }
        return recording.isFileURL && saved.allSatisfy(\.isFileURL)
            // A segment with end before start still renders safely; older
            // whisper.cpp output can contain one.
            && decoded.allSatisfy { time($0.start) && time($0.end) }
            && paragraphsAreValid(paragraphs)
            && paragraphsAreValid(originalParagraphs ?? [])
            && (duration.map(time) ?? true)
            && (resumedAt ?? []).allSatisfy(time)
            && (speech ?? []).allSatisfy { time($0.lowerBound) && time($0.upperBound) }
            && (transcribedIn.map { $0.isFinite && $0 >= 0 && $0 <= 365 * 24 * 60 * 60 } ?? true)
    }
}
