// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Entries as JSON files, one per transcript, in Application Support: a
/// recording transcribed twice has two. There is no separate index; the
/// directory listing is the library, as for glossaries and models.
nonisolated enum HistoryStore {
    static let directory = URL.applicationSupportDirectory.appending(path: "Polycop/History")

    /// What the library holds, and what of it could not be read.
    struct Library {
        var entries: [Entry] = []
        /// Records that could not be read, or the History folder's own name
        /// when it cannot be listed. Left exactly where they are, since a
        /// damaged file is the only copy of that transcript and may still be
        /// recoverable by hand.
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
        // `folders.json` lives in the same folder but is not an entry; isRecord
        // filters it out so it is never reported as a damaged record.
        let records = names.filter(isRecord).sorted()
        // Decoding is nearly all of a launch, and records do not depend on one
        // another, so they are decoded on every core at once: one by one, 200
        // three-hour lectures timed by word took ten seconds.
        let read = OSAllocatedUnfairLock(
            initialState: [Result<Entry, DamagedRecord>?](repeating: nil, count: records.count))
        DispatchQueue.concurrentPerform(iterations: records.count) { index in
            let result = record(folder.appending(path: records[index]))
            read.withLock { $0[index] = result }
        }
        var library = Library()
        for (name, result) in zip(records, read.withLock { $0 }) {
            switch result {
            case .success(let entry):
                library.entries.append(entry)
            case .failure(let damage):
                Log.persistence.error(
                    "a transcript record could not be read: \(damage.reason, privacy: .public)")
                library.damaged.append(name)
            case nil:
                library.damaged.append(name)
            }
        }
        library.entries.sort { $0.added > $1.added }
        return library
    }

    /// Which check a record failed, in words that hold none of its text: a
    /// record holds a lecture, and the log is read by whoever is sent it.
    struct DamagedRecord: Error {
        let reason: String
    }

    /// The entry a record holds, or which check it failed.
    static func record(
        _ file: URL, decoder: JSONDecoder = JSONDecoder()
    ) -> Result<Entry, DamagedRecord> {
        func damaged(_ reason: String) -> Result<Entry, DamagedRecord> {
            .failure(DamagedRecord(reason: reason))
        }
        func path(_ keys: [any CodingKey]) -> String {
            keys.isEmpty ? "the top" : keys.map(\.stringValue).joined(separator: ".")
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
        } catch DecodingError.keyNotFound(let key, let context) {
            return damaged("\(path(context.codingPath + [key])) is missing")
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(
            _, let context)
        {
            return damaged("\(path(context.codingPath)) has the wrong type")
        } catch DecodingError.dataCorrupted(let context) {
            return damaged("\(path(context.codingPath)) is not valid")
        } catch {
            return damaged("the file is not a record")
        }
        guard entry.id == UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
            return damaged("its id differs from the file name")
        }
        entry.repair()
        guard entry.hasValidHistory else { return damaged("a time or a path is out of bounds") }
        return .success(entry)
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
    /// Mends what a record can hold out of place without losing anything the
    /// user wrote. Before 0.4, MOSS could write a turn before the one it
    /// follows where voices overlap, and the record was refused: its segments
    /// and paragraphs are sorted by start, each text staying with its time.
    /// A playback position out of bounds is forgotten; the page already
    /// ignores a reading place it does not have.
    mutating func repair() {
        let order = paragraphs.indices.sorted { paragraphs[$0].start < paragraphs[$1].start }
        if order != Array(paragraphs.indices) {
            decoded.sort { $0.start < $1.start }
            paragraphs = order.map { paragraphs[$0] }
            originalParagraphs = originalParagraphs?.sorted { $0.start < $1.start }
            readingParagraph = readingParagraph.flatMap { order.firstIndex(of: $0) }
        }
        let ceiling = AudioDecoder.longestRecording + 60
        if let position = playbackPosition, !(0...ceiling).contains(position) {
            playbackPosition = nil
        }
    }

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
