// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing

@testable import Polycop

/// What a word processor would read back from a Word export.
@MainActor
private func readBack(_ data: Data) throws -> NSAttributedString {
    try NSAttributedString(
        data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
        documentAttributes: nil)
}

/// The title, then each paragraph after its time in bold, accents intact.
@MainActor
@Test func aWordExportReadsBackAsTheTranscript() throws {
    let paragraphs = [
        Transcript.Paragraph(start: 0, text: "Le cours d’Héloïse porte sur l’Œdipe."),
        Transcript.Paragraph(start: 83_000, text: "Deuxième partie."),
    ]

    let document = try readBack(try WordDocument.data(paragraphs, title: "Cours 3"))

    let lines = document.string.split(separator: "\n").map(String.init)
    #expect(
        lines == [
            "Cours 3", "00:00:00  Le cours d’Héloïse porte sur l’Œdipe.",
            "00:01:23  Deuxième partie.",
        ])
    let time = (document.string as NSString).range(of: "00:01:23")
    let font = try #require(
        document.attribute(.font, at: time.location, effectiveRange: nil) as? NSFont)
    #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
}

/// Choosing Word writes a .docx, and the record keeps a layout that versions
/// without Word export still read.
@MainActor
@Test func choosingWordExportsADocxAndKeepsTheRecordReadable() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    var entry = Entry(
        recording: folder.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 2, text: "Bonjour.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)

    model.setExport(.word, times: true, for: entry.id)
    let chosen = try #require(model.entry(entry.id))
    #expect(chosen.exportLayout == .word)
    #expect(chosen.textLayout != .word)

    let destination = folder.appending(path: "cours.docx")
    model.export(entry.id, to: destination)
    let exported = try #require(model.entry(entry.id))
    #expect(exported.saved == [destination])
    #expect(model.lastExport(of: exported) == destination)
    #expect(try readBack(try Data(contentsOf: destination)).string.contains("Bonjour."))

    await model.finishWrites()
    let json = try String(
        contentsOf: history.appending(path: "\(entry.id.uuidString).json"), encoding: .utf8)
    #expect(!json.contains("\"word\""))

    model.setExport(.plainText, times: false, for: entry.id)
    #expect(model.entry(entry.id)?.exportLayout == .plain)
    #expect(model.entry(entry.id)?.exportsWord == nil)
}

/// Each export is a new file: exporting again in another format leaves the
/// first file alone, and the new format becomes the transcript's.
@MainActor
@Test func exportingAgainInAnotherFormatMakesANewFile() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    var entry = Entry(
        recording: folder.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 2, text: "Bonjour.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    let text = folder.appending(path: "cours.txt")
    model.export(entry.id, as: .plainText, times: true, to: text)
    #expect(model.lastExport(of: try #require(model.entry(entry.id))) == text)

    let document = folder.appending(path: "cours.docx")
    model.export(entry.id, as: .word, times: true, to: document)

    let exported = try #require(model.entry(entry.id))
    #expect(exported.saved == [document])
    #expect(exported.exportLayout == .word)
    #expect(model.lastExport(of: exported) == document)
    #expect(try readBack(try Data(contentsOf: document)).string.contains("Bonjour."))
    #expect(FileManager.default.fileExists(atPath: text.path(percentEncoded: false)))
    await model.finishWrites()
}

/// Timecodes are one choice for every format. Plain text keeps it in its
/// layout and Word apart from it, which earlier versions read.
@MainActor
@Test func timecodesCanBeLeftOutOfEveryFormat() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    var entry = Entry(
        recording: folder.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 2, text: "Bonjour.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    #expect(try #require(model.entry(entry.id)).exportsTimes)

    model.export(entry.id, as: .markdown, times: false, to: folder.appending(path: "cours.md"))
    let markdown = try String(contentsOf: folder.appending(path: "cours.md"), encoding: .utf8)
    #expect(markdown.contains("Bonjour."))
    #expect(!markdown.contains("00:00"))

    model.export(entry.id, as: .word, times: false, to: folder.appending(path: "cours.docx"))
    let document = try readBack(try Data(contentsOf: folder.appending(path: "cours.docx")))
    #expect(document.string.contains("Bonjour."))
    #expect(!document.string.contains("00:00"))
    #expect(model.entry(entry.id)?.exportsWord == true)

    model.setExport(.plainText, times: false, for: entry.id)
    #expect(model.entry(entry.id)?.textLayout == .plain)
    model.setExport(.plainText, times: true, for: entry.id)
    #expect(model.entry(entry.id)?.textLayout == .timestamped)
    #expect(model.entry(entry.id)?.exportsTimes == true)
    await model.finishWrites()
}
