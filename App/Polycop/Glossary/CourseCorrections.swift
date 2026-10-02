// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A replacement remembered for a course, applied to its next transcripts.
nonisolated struct CourseCorrection: Codable, Equatable, Hashable, Sendable {
    /// The words as the engine writes them.
    let text: String
    let replacement: String
}

/// The corrections of each course, in a JSON file beside its glossary.
nonisolated enum CourseCorrections {
    /// A corrections file that exists but cannot be read or decoded.
    struct Unreadable: LocalizedError {
        let course: String

        var errorDescription: String? {
            String(
                localized:
                    "The corrections remembered for \(course) could not be read. Their file is left as it is, and none are applied until it can be read."
            )
        }
    }

    /// Adds a correction, replacing one for the same text.
    static func remember(
        _ correction: CourseCorrection, for glossary: String,
        in folder: URL = GlossaryStore.directory
    ) throws {
        let kept = try all(for: glossary, in: folder).filter {
            $0.text.compare(correction.text, options: [.caseInsensitive, .diacriticInsensitive])
                != .orderedSame
        }
        try save(kept + [correction], for: glossary, in: folder)
    }

    static func forget(
        _ correction: CourseCorrection, for glossary: String,
        in folder: URL = GlossaryStore.directory
    ) throws {
        try save(
            all(for: glossary, in: folder).filter { $0 != correction }, for: glossary,
            in: folder)
    }

    /// Goes to the Trash with its glossary.
    static func delete(for glossary: String, in folder: URL = GlossaryStore.directory) {
        try? FileManager.default.trashItem(
            at: file(for: glossary, in: folder), resultingItemURL: nil)
    }

    /// No file means no corrections yet. A file that cannot be read throws,
    /// so that saving never writes over the corrections it holds, and the
    /// user is told rather than shown none.
    static func all(
        for glossary: String, in folder: URL = GlossaryStore.directory
    ) throws -> [CourseCorrection] {
        do {
            let data = try Data(contentsOf: file(for: glossary, in: folder))
            return try JSONDecoder().decode([CourseCorrection].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw Unreadable(course: glossary)
        }
    }

    private static func save(
        _ corrections: [CourseCorrection], for glossary: String, in folder: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(corrections).write(
            to: file(for: glossary, in: folder), options: .atomic)
    }

    private static func file(for glossary: String, in folder: URL) -> URL {
        folder.appending(path: glossary + ".corrections.json")
    }
}
