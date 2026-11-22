// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// Splits plain text into fixed-line blocks so running headers can be detected.
@Test func documentsReadsPlainTextIntoBlocks() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let notes = folder.appending(path: "notes.txt")
    let text = (1...50).map { "ligne \($0)" }.joined(separator: "\n")
    try Data(text.utf8).write(to: notes)

    let pages = try await Documents.pages(of: notes)
    #expect(pages.count == 2)
    #expect(pages.first?.contains("ligne 1") == true)
}

/// Refuses plain text files larger than `Documents.largestText`.
@Test func documentsRefusesPlainTextAboveSizeLimit() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let largeText = folder.appending(path: "large.txt")
    try createSparseFile(at: largeText, bytes: Documents.largestText + 1)
    await #expect {
        _ = try await Documents.pages(of: largeText)
    } throws: { error in
        guard case DocumentError.tooLarge(let rejected) = error else { return false }
        return rejected == largeText
    }
}

/// Refuses PDF files larger than `Documents.largest` before opening them.
@Test func documentsRefusesPDFAboveSizeLimit() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let largePDF = folder.appending(path: "large.pdf")
    try createSparseFile(at: largePDF, bytes: Documents.largest + 1)
    await #expect {
        _ = try await Documents.pages(of: largePDF)
    } throws: { error in
        guard case DocumentError.tooLarge(let rejected) = error else { return false }
        return rejected == largePDF
    }
}

/// Refuses corrupted PDF data that PDFKit cannot parse.
@Test func documentsRefusesUnreadablePDF() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let brokenPDF = folder.appending(path: "broken.pdf")
    try Data([0, 1, 2]).write(to: brokenPDF)
    await #expect {
        _ = try await Documents.pages(of: brokenPDF)
    } throws: { error in
        guard case DocumentError.unreadable(let rejected) = error else { return false }
        return rejected == brokenPDF
    }
}

private func makeTemporaryFolder() throws -> URL {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func createSparseFile(at file: URL, bytes: Int) throws {
    try Data().write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(bytes))
}
