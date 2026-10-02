// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// Renaming changes the name in the library and nothing else, and lasts
/// after a relaunch. The recording's own file name gives the title back to
/// it, and an empty name changes nothing.
@MainActor
@Test func renamingATranscriptChangesOnlyItsName() async throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: URL(filePath: "/tmp/Cours 12.m4a"), modelFile: ModelCatalog.recommended.id,
        glossary: Glossary(name: "Philosophie", text: "Descartes"), skipsSilence: false,
        subtitles: false)
    entry.publish([Segment(start: 0, end: 4, text: "Bonjour à tous.")], partial: false)
    entry.state = .finished
    entry.edit(paragraphAt: 0, text: "Bonjour à toutes et à tous.")
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)

    model.rename(entry.id, to: "  Le cogito  ")
    await model.finishWrites()

    let renamed = try #require(AppModel(history: history).entry(entry.id))
    #expect(renamed.name == "Le cogito")
    #expect(renamed.recording == entry.recording)
    #expect(renamed.paragraphs == entry.paragraphs && renamed.original == entry.original)
    #expect(renamed.decoded == entry.decoded && renamed.glossary == entry.glossary)
    #expect(renamed.state == .finished && renamed.isEdited)

    model.rename(entry.id, to: " ")
    #expect(model.entry(entry.id)?.name == "Le cogito")
    model.rename(entry.id, to: "Cours 12.m4a")
    #expect(model.entry(entry.id)?.title == nil)
    #expect(model.entry(entry.id)?.name == "Cours 12.m4a")
}
