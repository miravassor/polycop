// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

@MainActor
@Test func foldersPersistWithoutMovingAudioAndCanOnlyBeDeletedWhenEmpty() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    let audio = history.appending(path: "lecture.wav")
    var entry = Entry(
        recording: audio, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    let folder = try model.createFolder(named: " Philosophy ")
    #expect(try model.createFolder(named: "philosophy") == folder)
    model.moveEntry(entry.id, to: folder)
    try model.removeFolder(folder)
    #expect(model.folders.count == 1)
    try model.renameFolder(folder, to: "Ethics")
    let reloaded = AppModel(history: history)
    #expect(reloaded.folders.first?.name == "Ethics")
    #expect(reloaded.entry(entry.id)?.folderID == folder)
    #expect(reloaded.entry(entry.id)?.recording == audio)
    reloaded.moveEntry(entry.id, to: nil)
    try reloaded.removeFolder(folder)
    #expect(try HistoryStore.folders(in: history).isEmpty)
    #expect(HistoryStore.all(in: history).entries.first?.folderID == nil)
}

@MainActor
@Test func aTranscriptIsDraggedIntoAFolderAndBackOut() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: history.appending(path: "lecture.wav"),
        modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
        subtitles: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    let folder = try model.createFolder(named: "Philosophy")

    #expect(model.moveEntries([entry.id.uuidString], to: folder))
    #expect(model.entry(entry.id)?.folderID == folder)
    #expect(model.moveEntries([entry.id.uuidString], to: nil))
    #expect(model.entry(entry.id)?.folderID == nil)
    // What the Finder hands over is a path, and an unknown transcript is gone.
    #expect(!model.moveEntries(["/Users/someone/cours.wav"], to: folder))
    #expect(!model.moveEntries([UUID().uuidString], to: folder))
    #expect(model.entry(entry.id)?.folderID == nil)
}

private func temporaryFolder() throws -> URL {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func entry(_ name: String, in folder: URL, added: Date = .now) -> Entry {
    Entry(
        recording: folder.appending(path: name), modelFile: ModelCatalog.recommended.id,
        glossary: Glossary(name: "Philosophie", text: "Descartes"), skipsSilence: false,
        subtitles: true, added: added)
}

@Test func anEntryIsFoundAgainFromTheFolder() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var written = entry("cours.m4a", in: folder)
    written.publish(
        [
            Segment(start: 0, end: 2, text: " Bonjour."),
            Segment(start: 2, end: 4, text: " Descartes."),
        ],
        partial: false)
    written.state = .finished
    written.edit(paragraphAt: 0, text: "Bonjour, corrigé.")

    try HistoryStore.write(written, in: folder)

    #expect(HistoryStore.all(in: folder).entries == [written])
    #expect(written.prompt == "Ce cours porte sur Descartes.")
}

@Test func aDamagedRecordHidesNothingElse() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try HistoryStore.write(entry("cours.m4a", in: folder), in: folder)
    try Data("{ pas du JSON".utf8).write(to: folder.appending(path: "abîmé.json"))

    #expect(HistoryStore.all(in: folder).entries.count == 1)
}

@Test func entriesAreListedNewestFirst() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let older = entry("lundi.m4a", in: folder, added: .now.addingTimeInterval(-60))
    let newer = entry("mardi.m4a", in: folder)
    try HistoryStore.write(older, in: folder)
    try HistoryStore.write(newer, in: folder)

    #expect(HistoryStore.all(in: folder).entries.map(\.name) == ["mardi.m4a", "lundi.m4a"])
}

/// The bookmark follows a recording moved on the same disk, so replay still
/// finds a lecture tidied into another folder.
@Test func aMovedRecordingIsFoundThroughItsBookmark() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appending(path: "cours.m4a")
    try Data("audio".utf8).write(to: original)
    let recorded = entry("cours.m4a", in: folder)
    let tidied = folder.appending(path: "Semestre 3")
    try FileManager.default.createDirectory(at: tidied, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: original, to: tidied.appending(path: "cours.m4a"))

    #expect(
        recorded.location.resolvingSymlinksInPath().path
            == tidied.appending(path: "cours.m4a").resolvingSymlinksInPath().path)
}

/// A looped window is shortened like a credit line is hidden, and its words
/// come back whole with the credits.
@Test func aShortenedLoopComesBackWhenPutBack() throws {
    let loop = Array(repeating: "Merci", count: 512).joined(separator: " ")
    var looped = entry("cours.m4a", in: URL.temporaryDirectory)
    looped.publish(
        [
            Segment(start: 0, end: 30, text: loop),
            Segment(start: 32, end: 60, text: "Bonjour à tous."),
        ], partial: false)
    #expect(looped.paragraphs.map(\.text) == ["Merci Merci", "Bonjour à tous."])
    #expect(looped.shortenedLoops.count == 1)

    looped.putBackCredits()

    #expect(looped.shortenedLoops.isEmpty)
    #expect(looped.paragraphs.first?.text == loop)
}

/// Hidden credits stay out of the text until put back, and putting them back is
/// refused once the text is corrected, since the layout would change under it.
@Test func creditsComeBackOnlyBeforeCorrections() throws {
    let result = [
        Segment(start: 0, end: 30, text: " Sous-titrage Société Radio-Canada"),
        Segment(start: 31, end: 33, text: " Bonjour à tous."),
    ]
    var corrected = entry("cours.m4a", in: URL.temporaryDirectory)
    corrected.publish(result, partial: false)
    #expect(corrected.paragraphs.map(\.text) == ["Bonjour à tous."])
    #expect(corrected.hiddenCredits.count == 1)

    var untouched = corrected
    corrected.edit(paragraphAt: 0, text: "Bonjour à toutes.")
    corrected.putBackCredits()
    #expect(!corrected.showsCredits)

    untouched.putBackCredits()
    // One second of silence between them, so the line joins the paragraph.
    #expect(
        untouched.paragraphs.map(\.text) == ["Sous-titrage Société Radio-Canada Bonjour à tous."])
    #expect(untouched.hiddenCredits.isEmpty)
}

/// What the detector left out is the recording less what it kept, each second
/// counted once and only within the recording.
@Test func whatTheDetectorLeftOutIsCountedOnce() {
    var skipped = entry("cours.m4a", in: URL.temporaryDirectory)
    #expect(skipped.leftOut == nil)

    skipped.duration = 100
    skipped.speech = [50...70, 10...30, 20...40, 95...120]

    // Kept: 10 to 40, 50 to 70, 95 to 100, so 55 seconds of 100.
    #expect(skipped.leftOut == 45)
}

/// A resume point marks the paragraph holding it, so a user knows where to
/// listen.
@Test func aResumePointMarksItsParagraph() {
    var resumed = entry("cours.m4a", in: URL.temporaryDirectory)
    resumed.publish(
        [
            Segment(start: 0, end: 4, text: " Premier."),
            Segment(start: 10, end: 14, text: " Deuxième."),
            Segment(start: 20, end: 24, text: " Troisième."),
        ], partial: false)
    resumed.resumedAt = [15, 2, 25]

    #expect(resumed.paragraphs.count == 3)
    #expect(resumed.resumedParagraphs == [0, 1, 2])

    resumed.resumedAt = [12]
    #expect(resumed.resumedParagraphs == [1])
}

@MainActor
@Test func correctionsStepBackOneAtATimeAndCanBeThrownAway() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: history.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish(
        [Segment(start: 0, end: 4, text: "Le principe de plaisir.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)

    #expect(!model.canUndo(entry.id))
    model.edit(entry.id, paragraphAt: 0, text: "Le principe de réalité.")
    model.edit(entry.id, paragraphAt: 0, text: "Le principe de réalité selon Freud.")
    #expect(model.entry(entry.id)?.isEdited == true)

    model.undo(entry.id)
    #expect(model.entry(entry.id)?.paragraphs.first?.text == "Le principe de réalité.")
    model.undo(entry.id)
    #expect(model.entry(entry.id)?.paragraphs.first?.text == "Le principe de plaisir.")
    // Back at what the engine wrote, so nothing is marked as corrected.
    #expect(model.entry(entry.id)?.isEdited == false)
    #expect(!model.canUndo(entry.id))

    model.edit(entry.id, paragraphAt: 0, text: "Autre chose.")
    model.revert(entry.id)
    #expect(model.entry(entry.id)?.paragraphs.first?.text == "Le principe de plaisir.")
    #expect(model.entry(entry.id)?.isEdited == false)
    // A revert is itself a step, so it can be taken back.
    #expect(model.canUndo(entry.id))
}

@MainActor
@Test func aDuplicateCarriesTheTextAndTakesTheNextNumber() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: history.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 4, text: "Le cours.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)

    let second = try #require(model.duplicate(entry.id))
    let third = try #require(model.duplicate(entry.id))

    #expect(model.entry(second)?.name == "cours 2.wav")
    #expect(model.entry(third)?.name == "cours 3.wav")
    #expect(model.entry(second)?.paragraphs == model.entry(entry.id)?.paragraphs)
    #expect(model.entry(second)?.recording == model.entry(entry.id)?.recording)
    // Each one is corrected on its own.
    model.edit(second, paragraphAt: 0, text: "Autre texte.")
    #expect(model.entry(entry.id)?.paragraphs.first?.text == "Le cours.")
    #expect(HistoryStore.all(in: history).entries.count == 3)
}

@Test func legacyCorrectionsKeepTheirOriginalParagraphBoundaries() throws {
    var old = entry("cours.wav", in: URL.temporaryDirectory)
    old.decoded = [
        Segment(start: 0, end: 90, text: "First part."),
        Segment(start: 90, end: 100, text: "Second part."),
    ]
    old.paragraphs = [.init(start: 0, text: "First part. Second part.")]
    #expect(Transcript.paragraphs(old.shown).count == 2)
    #expect(old.original == old.paragraphs)
    old.edit(paragraphAt: 0, text: "Correction.")
    let restored = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(old))
    #expect(restored.original.map(\.text) == ["First part. Second part."])
    old.edit(paragraphAt: 0, text: "First part. Second part.")
    #expect(!old.isEdited)
}

/// Putting the credits back rebuilds the paragraphs, so it is refused while a
/// reverted correction can still be stepped back.
@MainActor
@Test func creditsStayHiddenWhileACorrectionCanBeSteppedBack() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: history.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish(
        [
            Segment(start: 0, end: 30, text: " Sous-titrage Société Radio-Canada"),
            Segment(start: 31, end: 33, text: " Bonjour à tous."),
        ], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)

    model.edit(entry.id, paragraphAt: 0, text: "Bonjour à toutes.")
    model.revert(entry.id)
    #expect(model.entry(entry.id)?.isEdited == false)
    #expect(model.canUndo(entry.id))
    #expect(!model.canPutBackCredits(of: try #require(model.entry(entry.id))))

    model.putBackCredits(entry.id)
    #expect(model.entry(entry.id)?.showsCredits == false)
    #expect(model.canUndo(entry.id))
}

@Test func replaceAllCorrectsEverySpellingOfAWord() {
    var entry = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish(
        [
            Segment(start: 0, end: 4, text: "Le trouble bordéreux et le Bordereux."),
            Segment(start: 30, end: 34, text: "Un patient bordereux."),
        ], partial: false)
    let original = entry.paragraphs
    let matches = TranscriptSearch.matches(in: entry.paragraphs, query: "bordereux")
    #expect(matches.count == 3)

    entry.replace(matches, with: "borderline")

    #expect(entry.paragraphs.map(\.text).joined(separator: " ").contains("bordereux") == false)
    #expect(entry.paragraphs.map(\.text).joined().components(separatedBy: "borderline").count == 4)
    #expect(entry.isEdited)
    #expect(entry.original == original)
}

@MainActor
@Test func aReplacementIsOneCorrectionToUndo() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: history.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish(
        [
            Segment(start: 0, end: 4, text: "Le trouble bordéreux."),
            Segment(start: 30, end: 34, text: "Un patient bordereux."),
        ], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    let before = try #require(model.entry(entry.id)).paragraphs

    let unchanged = TranscriptSearch.matches(in: before, query: "patient")
    model.replace(entry.id, matches: unchanged, with: "patient")
    #expect(!model.canUndo(entry.id))

    let matches = TranscriptSearch.matches(in: before, query: "bordereux")
    model.replace(entry.id, matches: matches, with: "borderline")
    #expect(model.entry(entry.id)?.paragraphs != before)
    model.undo(entry.id)
    #expect(model.entry(entry.id)?.paragraphs == before)
    #expect(!model.canUndo(entry.id))
}

/// The export writes the layout chosen for this transcript, and a new layout
/// makes the earlier export out of date.
@MainActor
@Test func theExportFollowsTheTranscriptsLayout() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let history = folder.appending(path: "History")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var entry = Entry(
        recording: folder.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 4, text: "Euh, bonjour à tous.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)

    model.setTextLayout(.markdown, for: entry.id)
    model.setRemovesHesitations(true, for: entry.id)
    model.export(entry.id, to: folder.appending(path: "Cours.txt"))

    let written = try String(contentsOf: folder.appending(path: "Cours.md"), encoding: .utf8)
    #expect(written.hasPrefix("# cours\n"))
    #expect(written.contains("**00:00:00** Bonjour à tous."))
    let exported = try #require(model.entry(entry.id))
    #expect(model.exportState(of: exported) == .current)

    model.setTextLayout(.plain, for: entry.id)
    #expect(model.exportState(of: try #require(model.entry(entry.id))) == .none)
    model.setTextLayout(.markdown, for: entry.id)
    #expect(model.exportState(of: try #require(model.entry(entry.id))) == .outOfDate)
}

/// Typing is written after a pause rather than at each key, and what is left
/// is written before quitting.
@MainActor
@Test func typingIsWrittenAfterAPause() async throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: history.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 4, text: "Bonjour à tous.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    let file = history.appending(path: entry.id.uuidString + ".json")
    func written() throws -> String? {
        try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file)).paragraphs.first?.text
    }

    model.edit(entry.id, paragraphAt: 0, text: "Bonjour à toutes.")
    #expect(try written() == "Bonjour à tous.")
    try await Task.sleep(for: .seconds(1.5))
    #expect(try written() == "Bonjour à toutes.")

    model.edit(entry.id, paragraphAt: 0, text: "Bonsoir à toutes.")
    #expect(model.retrySavingHistory())
    #expect(try written() == "Bonsoir à toutes.")
}
