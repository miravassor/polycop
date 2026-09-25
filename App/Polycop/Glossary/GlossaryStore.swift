// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Glossaries as plain text files, one per course, in Application Support.
/// There is no separate index; the directory listing is the library, as for
/// models.
nonisolated enum GlossaryStore {
    static let directory = URL.applicationSupportDirectory.appending(path: "Polycop/Glossaries")

    /// Far above any real glossary (the model reads at most 223 tokens, about
    /// 700 characters). Keeps a file picked by mistake from being read and
    /// tokenized whole.
    static let largestImport = 100_000

    enum ImportError: LocalizedError {
        case tooLarge
        case notText

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return String(
                    localized:
                        "This file is too large to be a glossary, which is a short list of terms, one per line."
                )
            case .notText:
                return String(
                    localized:
                        "This file is not plain text. Save it as text, one term per line, and import it again."
                )
            }
        }
    }

    static func all(in folder: URL = directory) -> [Glossary] {
        let path = folder.path(percentEncoded: false)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        return
            files
            .filter { $0.hasSuffix(".txt") }
            .compactMap { file in
                guard let text = try? contents(of: folder.appending(path: file)) else {
                    return nil
                }
                return Glossary(name: (file as NSString).deletingPathExtension, text: text)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(_ glossary: Glossary, in folder: URL = directory) throws {
        guard glossary.text.utf8.count <= largestImport else { throw ImportError.tooLarge }
        guard !glossary.name.isEmpty, !glossary.name.contains("/"), !glossary.name.contains("\u{0}")
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try glossary.text.write(
            to: file(named: glossary.name, in: folder), atomically: true, encoding: .utf8)
    }

    /// Moves the file to the Trash rather than deleting it outright, since a
    /// glossary is typed by hand and cannot be downloaded again.
    static func delete(named name: String, in folder: URL = directory) throws {
        try FileManager.default.trashItem(at: file(named: name, in: folder), resultingItemURL: nil)
    }

    /// Reads a text file as a new glossary named after it. A prompt sentence
    /// such as "Ce cours porte sur ..." is turned into one term per line on
    /// the way in.
    static func importFile(_ source: URL, in folder: URL = directory) throws -> Glossary {
        let raw = try contents(of: source)
        // Plain text never contains a null character; passed to C, one would
        // end the prompt early, and both the model and the token count would
        // stop there.
        guard !raw.contains("\u{0}") else { throw ImportError.notText }
        let name = freeName(for: source.deletingPathExtension().lastPathComponent, in: folder)
        let glossary = Glossary(name: name, text: Glossary.terms(in: raw).joined(separator: "\n"))
        try save(glossary, in: folder)
        return glossary
    }

    /// A course name usable as a file name and free in the folder.
    static func freeName(for wanted: String, in folder: URL = directory) -> String {
        let cleaned =
            wanted
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let stem = cleaned.isEmpty ? "Course" : cleaned
        var attempt = 1
        while true {
            let name = attempt == 1 ? stem : "\(stem) \(attempt)"
            let path = file(named: name, in: folder).path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: path) { return name }
            attempt += 1
        }
    }

    static func location(of name: String, in folder: URL = directory) -> URL {
        file(named: name, in: folder)
    }

    private static func contents(of file: URL) throws -> String {
        guard file.isFileURL,
            try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { throw ImportError.notText }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: largestImport + 1) ?? Data()
        guard data.count <= largestImport else { throw ImportError.tooLarge }
        guard let text = TextFile.decode(data) else { throw ImportError.notText }
        return text
    }

    private static func file(named name: String, in folder: URL) -> URL {
        folder.appending(path: name + ".txt")
    }
}
