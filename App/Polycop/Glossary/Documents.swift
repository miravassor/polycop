// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

nonisolated enum DocumentError: LocalizedError {
    case unreadable(URL)
    case tooLarge(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let file):
            String(localized: "This file could not be read: \(file.lastPathComponent)")
        case .tooLarge(let file):
            String(localized: "This file is too large to read: \(file.lastPathComponent)")
        }
    }
}

/// Course material opened for its words alone.
///
/// Slides or notes go in, pages of plain text come out; nothing is kept.
/// Pages are returned separately, not joined, so a name repeated on every
/// page can be recognised as a header rather than a term.
nonisolated enum Documents {
    static let wordProcessing = UTType("org.openxmlformats.wordprocessingml.document")

    /// Ordered roughly by frequency: PDF slides first, plain-text notes second.
    static var readable: [UTType] {
        [.pdf, .plainText, .rtf] + [wordProcessing].compactMap { $0 }
    }

    /// The whole text is held in memory while terms are counted, so this is
    /// not meant for gigabyte-scale documents.
    static let largest = 50 << 20
    static let largestText = 5 << 20

    /// A stricter ceiling for the compressed formats. A PDF is read page by
    /// page, but RTF and Word documents are built whole by the system importer
    /// before the text can be counted, and a few megabytes can expand into far
    /// more. A syllabus does not reach this size.
    static let largestSource = 5 << 20

    @concurrent
    static func pages(of file: URL, limit: Int = largest) async throws -> [String] {
        guard file.isFileURL,
            let values = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentTypeKey,
            ]), values.isRegularFile == true, let size = values.fileSize
        else { throw DocumentError.unreadable(file) }
        guard size <= limit else { throw DocumentError.tooLarge(file) }
        let type =
            values.contentType ?? UTType(filenameExtension: file.pathExtension) ?? .data

        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: file) else {
                throw DocumentError.unreadable(file)
            }
            guard document.pageCount <= 2000 else { throw DocumentError.tooLarge(file) }
            var pages: [String] = []
            var bytes = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let text = document.page(at: index)?.string else { continue }
                bytes += text.utf8.count
                guard bytes <= largestText else { throw DocumentError.tooLarge(file) }
                pages.append(text)
            }
            return pages
        }
        if let kind = reader(for: type) {
            guard size <= largestSource else { throw DocumentError.tooLarge(file) }
            // The type is named rather than sniffed, so a file that claims to
            // be HTML is not handed to the web importer.
            let text = try NSAttributedString(
                url: file, options: [.documentType: kind], documentAttributes: nil
            ).string
            guard text.utf8.count <= largestText else { throw DocumentError.tooLarge(file) }
            try Task.checkCancellation()
            return blocks(of: text)
        }
        guard type.conforms(to: .text) else { throw DocumentError.unreadable(file) }
        return blocks(of: try text(of: file, limit: min(limit, largestText)))
    }

    private static func reader(for type: UTType) -> NSAttributedString.DocumentType? {
        if let wordProcessing, type.conforms(to: wordProcessing) { return .officeOpenXML }
        return type.conforms(to: .rtf) ? .rtf : nil
    }

    /// Cuts a document without pages into blocks of a few dozen lines each, so
    /// a running header repeats across blocks the way it would across PDF
    /// pages.
    static func blocks(of text: String, lines linesPerBlock: Int = 40) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !lines.isEmpty else { return [] }
        return stride(from: 0, to: lines.count, by: linesPerBlock).map {
            lines[$0..<min($0 + linesPerBlock, lines.count)].joined(separator: "\n")
        }
    }

    private static func text(of file: URL, limit: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DocumentError.tooLarge(file) }
        guard let text = TextFile.decode(data) else { throw DocumentError.unreadable(file) }
        return text
    }
}
