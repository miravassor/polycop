// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A replacement remembered for a course, applied to its next transcripts.
nonisolated struct CourseCorrection: Codable, Equatable, Hashable, Sendable {
    let find: String
    let replacement: String
}

/// The corrections of each course, in a JSON file beside its glossary.
nonisolated enum CourseCorrections {
    static func all(
        for glossary: String, in folder: URL = GlossaryStore.directory
    ) -> [CourseCorrection] {
        guard let data = try? Data(contentsOf: file(for: glossary, in: folder)) else { return [] }
        return (try? JSONDecoder().decode([CourseCorrection].self, from: data)) ?? []
    }

    /// Adds a correction, replacing one that finds the same text.
    static func remember(
        _ correction: CourseCorrection, for glossary: String,
        in folder: URL = GlossaryStore.directory
    ) throws {
        let kept = all(for: glossary, in: folder).filter {
            $0.find.compare(correction.find, options: [.caseInsensitive, .diacriticInsensitive])
                != .orderedSame
        }
        try save(kept + [correction], for: glossary, in: folder)
    }

    static func forget(
        _ correction: CourseCorrection, for glossary: String,
        in folder: URL = GlossaryStore.directory
    ) throws {
        try save(
            all(for: glossary, in: folder).filter { $0 != correction }, for: glossary, in: folder)
    }

    /// Goes to the Trash with its glossary.
    static func delete(for glossary: String, in folder: URL = GlossaryStore.directory) {
        try? FileManager.default.trashItem(
            at: file(for: glossary, in: folder), resultingItemURL: nil)
    }

    /// Applies each correction as the user's own, so it can be compared with
    /// what the engine wrote and undone.
    static func apply(_ corrections: [CourseCorrection], to entry: inout Entry) {
        for correction in corrections {
            entry.replace(
                TranscriptSearch.matches(in: entry.paragraphs, query: correction.find),
                with: correction.replacement)
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
