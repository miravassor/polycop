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

    model.setTextLayout(.word, for: entry.id)
    let chosen = try #require(model.entry(entry.id))
    #expect(chosen.exportLayout == .word)
    #expect(chosen.textLayout != .word)

    let destination = folder.appending(path: "cours.docx")
    model.export(entry.id, to: destination)
    let exported = try #require(model.entry(entry.id))
    #expect(exported.saved == [destination])
    #expect(model.exportState(of: exported) == .current)
    #expect(try readBack(try Data(contentsOf: destination)).string.contains("Bonjour."))

    await model.finishWrites()
    let json = try String(
        contentsOf: history.appending(path: "\(entry.id.uuidString).json"), encoding: .utf8)
    #expect(!json.contains("\"word\""))

    model.setTextLayout(.plain, for: entry.id)
    #expect(model.entry(entry.id)?.exportLayout == .plain)
    #expect(model.entry(entry.id)?.exportsWord == nil)
}
