// SPDX-License-Identifier: GPL-3.0-or-later
// Every test of one subject, kept together.
// swiftlint:disable file_length

import Foundation
import Observation
import Testing
import UniformTypeIdentifiers
import os

@testable import Polycop

@MainActor
@Test func foldersPersistWithoutMovingAudioAndCanOnlyBeDeletedWhenEmpty() async throws {
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
    await model.finishWrites()
    let reloaded = AppModel(history: history)
    #expect(reloaded.folders.first?.name == "Ethics")
    #expect(reloaded.entry(entry.id)?.folderID == folder)
    #expect(reloaded.entry(entry.id)?.recording == audio)
    reloaded.moveEntry(entry.id, to: nil)
    try reloaded.removeFolder(folder)
    await reloaded.finishWrites()
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

    #expect(model.moveEntries([entry.id], to: folder))
    #expect(model.entry(entry.id)?.folderID == folder)
    #expect(model.moveEntries([entry.id], to: nil))
    #expect(model.entry(entry.id)?.folderID == nil)
    // A transcript not in this library, such as one from another copy.
    #expect(!model.moveEntries([UUID()], to: folder))
    #expect(model.entry(entry.id)?.folderID == nil)
}

/// Rows travel as the app's own type, declared in its Info.plist, never as
/// text, which a paragraph would take into the transcript, and arrive as they
/// left.
@Test func draggedRowsAreNotText() async throws {
    #expect(UTType.transcripts.isDeclared)
    #expect(!UTType.transcripts.conforms(to: .text))
    guard #available(macOS 15.2, *) else { return }
    #expect(DraggedTranscripts.exportedContentTypes() == [.transcripts])
    let dragged = DraggedTranscripts(ids: [UUID(), UUID()])
    let data = try await dragged.exported(as: .transcripts)
    #expect(try JSONDecoder().decode(DraggedTranscripts.self, from: data).ids == dragged.ids)
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

/// A turn that starts before the one it follows, as MOSS can write where
/// speakers overlap, still opens after a relaunch.
@Test func segmentsWrittenOutOfOrderStillOpen() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var written = entry("cours.m4a", in: folder)
    written.publish(
        [
            Segment(start: 12, end: 15, text: "Bonjour à tous.", speaker: "S01"),
            Segment(start: 10, end: 11, text: "Bonjour.", speaker: "S02"),
            Segment(start: 10, end: 12, text: "Pardon.", speaker: "S03"),
        ], partial: false)
    try HistoryStore.write(written, in: folder)

    #expect(HistoryStore.all(in: folder).entries == [written])
    #expect(written.decoded.map(\.text) == ["Bonjour.", "Pardon.", "Bonjour à tous."])
}

/// A lecture's own number is part of its name: a second transcript of
/// "Cours 12" must not take lecture 2's name.
@Test func aSecondTranscriptKeepsTheLecturesNumber() {
    let lecture = URL(filePath: "/tmp/Cours 12.m4a")
    #expect(
        Entry.freeName(from: "Cours 12.m4a", of: lecture, among: ["Cours 12.m4a"])
            == "Cours 12 (2).m4a")
    #expect(
        Entry.freeName(
            from: "Cours 12 (2).m4a", of: lecture, among: ["Cours 12.m4a", "Cours 12 (2).m4a"])
            == "Cours 12 (3).m4a")
    #expect(Entry.freeName(from: "Cours 12", of: lecture, among: ["Cours 12"]) == "Cours 12 (2)")
    // A renamed transcript keeps what follows its dot.
    #expect(Entry.freeName(from: "Séance 3.2", of: lecture, among: []) == "Séance 3.2 (2)")
}

/// One process holds the library; a second claim on it, as a second copy
/// of the app makes, is refused.
@Test func aLibraryIsClaimedOnce() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    #expect(HistoryStore.claim(folder))
    #expect(!HistoryStore.claim(folder))
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
    #expect(looped.findings.shortenedLoops.count == 1)

    looped.putBackCredits()

    #expect(looped.findings.shortenedLoops.isEmpty)
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
    #expect(corrected.findings.hiddenCredits.count == 1)

    var untouched = corrected
    corrected.edit(paragraphAt: 0, text: "Bonjour à toutes.")
    corrected.putBackCredits()
    #expect(!corrected.showsCredits)

    untouched.putBackCredits()
    // One second of silence between them, so the line joins the paragraph.
    #expect(
        untouched.paragraphs.map(\.text) == ["Sous-titrage Société Radio-Canada Bonjour à tous."])
    #expect(untouched.findings.hiddenCredits.isEmpty)
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
@Test func aDuplicateCarriesTheTextAndTakesTheNextNumber() async throws {
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

    #expect(model.entry(second)?.name == "cours (2).wav")
    #expect(model.entry(third)?.name == "cours (3).wav")
    #expect(model.entry(second)?.paragraphs == model.entry(entry.id)?.paragraphs)
    #expect(model.entry(second)?.recording == model.entry(entry.id)?.recording)
    // Each one is corrected on its own.
    model.edit(second, paragraphAt: 0, text: "Autre texte.")
    await model.finishWrites()
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
    #expect(!model.canRebuildParagraphs(of: try #require(model.entry(entry.id))))

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

/// A word retyped with a curly apostrophe is still found, replaced and
/// corrected, whichever apostrophe the query or the correction uses.
@Test func searchReadsBothApostrophesAsOne() throws {
    var entry = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish(
        [Segment(start: 0, end: 4, text: "🧪 L\u{2019}inconscient et l'inconscient.")],
        partial: false)
    let text = try #require(entry.paragraphs.first?.text) as NSString

    for query in ["l'inconscient", "l\u{2019}inconscient"] {
        let matches = TranscriptSearch.matches(in: entry.paragraphs, query: query)
        #expect(
            matches.map { text.substring(with: $0.range) }
                == ["L\u{2019}inconscient", "l'inconscient"])
    }

    entry.apply([CourseCorrection(text: "l\u{2019}inconscient", replacement: "l'Inconscient")])
    #expect(entry.paragraphs.first?.text == "🧪 l'Inconscient et l'Inconscient.")
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

/// The export writes the format chosen for this transcript. Another choice
/// marks the last export as no longer matching, which earlier versions read.
@MainActor
@Test func theExportFollowsTheTranscriptsLayout() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let history = folder.appending(path: "History")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var entry = Entry(
        recording: folder.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish(
        [
            Segment(start: 0, end: 4, text: "Euh, bonjour à tous."),
            Segment(start: 10, end: 11, text: "Euh."),
        ], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)

    model.setExport(.markdown, times: true, for: entry.id)
    model.setRemovesHesitations(true, for: entry.id)
    model.export(entry.id, to: folder.appending(path: "Cours.txt"))

    let written = try String(contentsOf: folder.appending(path: "Cours.md"), encoding: .utf8)
    #expect(written.hasPrefix("# cours\n"))
    #expect(written.contains("**00:00:00** Bonjour à tous."))
    // A paragraph that was only a hesitation leaves no bare time behind.
    #expect(!written.contains("00:00:10"))
    let exported = try #require(model.entry(entry.id))
    #expect(model.lastExport(of: exported) == folder.appending(path: "Cours.md"))
    #expect(exported.isSaved)

    model.setExport(.plainText, times: false, for: entry.id)
    #expect(model.entry(entry.id)?.isSaved == false)
}

/// "um" is a word in German: the option, carried from the last export, must not
/// take it out of the text.
@MainActor
@Test func aLanguageWithoutFillerWordsKeepsItsText() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    var entry = Entry(
        recording: folder.appending(path: "vorlesung.wav"), modelFile: "ggml-test.bin",
        glossary: nil, skipsSilence: false, subtitles: false, language: "de")
    entry.publish([Segment(start: 0, end: 4, text: "Wir beginnen um neun.")], partial: false)
    entry.state = .finished
    entry.removesHesitations = true
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)

    model.export(entry.id, as: .plainText, times: false, to: folder.appending(path: "V.txt"))

    let written = try String(contentsOf: folder.appending(path: "V.txt"), encoding: .utf8)
    #expect(written.contains("Wir beginnen um neun."))
}

/// A model that detects the language ignores the menu, so the menu's German says
/// nothing about what was spoken.
@Test func aDetectedLanguageKeepsTheFillerWordsOption() {
    let recording = URL(filePath: "/made/up.wav")
    let told = Entry(
        recording: recording, modelFile: ModelCatalog.turbo.id, glossary: nil,
        skipsSilence: false, subtitles: false, language: "de")
    let detected = Entry(
        recording: recording, modelFile: ModelCatalog.voxtral.id, glossary: nil,
        skipsSilence: false, subtitles: false, language: "de")
    #expect(!Hesitations.cover(told))
    #expect(Hesitations.cover(detected))
}

/// Automatic on a model that can be told a language counts as detected, and the
/// word stored is never taken for a language.
@Test(arguments: [ModelCatalog.turbo, ModelCatalog.qwen, ModelCatalog.voxtral])
func automaticIsADetectedLanguage(chosen: Model) {
    let entry = Entry(
        recording: URL(filePath: "/made/up.wav"), modelFile: chosen.id, glossary: nil,
        skipsSilence: false, subtitles: false, language: DecodingSettings.automaticLanguage)
    #expect(entry.isLanguageDetected)
    #expect(entry.toldLanguage == nil)
    #expect(Hesitations.cover(entry))
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
    for _ in 0..<100 {
        if try written() == "Bonjour à toutes." { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try written() == "Bonjour à toutes.")

    model.edit(entry.id, paragraphAt: 0, text: "Bonsoir à toutes.")
    #expect(await model.retrySavingHistory())
    #expect(try written() == "Bonsoir à toutes.")
}

/// Leaving a transcript keeps where it was read and heard, on disk as well, and
/// a transcript left before anything was reported keeps its earlier place.
@MainActor
@Test func leavingATranscriptKeepsWhereItWasLeft() async throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: URL(filePath: #filePath).deletingLastPathComponent().appending(
            path: "Fixtures/clip-fr.wav"),
        modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
        subtitles: false)
    entry.publish(
        [
            Segment(start: 0, end: 2, text: "Bonjour."),
            Segment(start: 3, end: 4, text: "Au revoir."),
        ],
        partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    defer { model.player.stop() }

    model.pane = .entry(entry.id)
    model.readingParagraph = 1
    model.replay(entry.id, from: 2, leadIn: 0)
    for _ in 0..<100 where !model.player.isOpen {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(model.player.isOpen)
    // A place asked of the player, which shows it at once: how far the audio
    // has played by now depends on how busy the machine is.
    model.player.seek(to: 2.5)
    model.pane = .new

    let left = try #require(model.entry(entry.id))
    #expect(left.readingParagraph == 1)
    #expect(left.playbackPosition == 2.5)
    await model.finishWrites()
    let written = AppModel(history: history).entry(entry.id)
    #expect(written?.readingParagraph == 1)
    #expect(written?.playbackPosition == 2.5)

    model.pane = .entry(entry.id)
    model.pane = .new
    #expect(model.entry(entry.id)?.readingParagraph == 1)
}

/// A repair transcribes a looped stretch with silence removal. What its
/// detector drops there is left out, on a transcript that had none before as
/// on one that skipped silences already.
@Test func aRepairRecordsWhatSilenceRemovalLeftOut() {
    let repaired = Entry.speech(
        nil, duration: 100, replacing: 40...60, with: [42...45, 50...55, 58...70])
    #expect(repaired == [0...40, 42...45, 50...55, 58...60, 60...100])

    let skipped = Entry.speech(
        [0...30, 35...50, 55...100], duration: 100, replacing: 40...60, with: [])
    #expect(skipped == [0...30, 35...40, 60...100])
}

/// whisper.cpp frees the context's state when it cannot allocate the
/// decoder's cache; the user is told to free memory rather than given a code.
@Test func runningOutOfDecoderMemorySaysWhatToDo() throws {
    let message = try #require(
        TranscriptionError.failed(WhisperEngine.cacheAllocationFailed).errorDescription)
    #expect(message.contains("memory"))
}

@MainActor
@Test func foldersStaySortedByNameOnLoadCreateAndRename() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    let model = AppModel(history: history, defaults: MemoryDefaults())
    _ = try model.createFolder(named: "Law")
    _ = try model.createFolder(named: "Folder 10")
    _ = try model.createFolder(named: "Folder 2")
    let biology = try model.createFolder(named: "Biology")
    #expect(model.folders.map(\.name) == ["Biology", "Folder 2", "Folder 10", "Law"])

    try model.renameFolder(biology, to: "Zoology")
    #expect(model.folders.map(\.name) == ["Folder 2", "Folder 10", "Law", "Zoology"])

    let reloaded = AppModel(history: history, defaults: MemoryDefaults())
    #expect(reloaded.folders.map(\.name) == ["Folder 2", "Folder 10", "Law", "Zoology"])

    let unsortedHistory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: unsortedHistory) }
    try HistoryStore.writeFolders(
        [
            TranscriptFolder(id: UUID(), name: "Philo"),
            TranscriptFolder(id: UUID(), name: "Arts"),
        ],
        in: unsortedHistory
    )
    let loaded = AppModel(history: unsortedHistory, defaults: MemoryDefaults())
    #expect(loaded.folders.map(\.name) == ["Arts", "Philo"])
}

@Test func librarySortOrdersEntriesByDateAddedOrName() {
    let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let directory = URL.temporaryDirectory
    let older = entry("Lecture 2.m4a", in: directory, added: base)
    let middle = entry("Lecture 10.m4a", in: directory, added: base.addingTimeInterval(60))
    var renamedFirst = entry("Zebra.m4a", in: directory, added: base.addingTimeInterval(120))
    renamedFirst.title = "Ethics"
    let duplicateOlder = entry("Notes.m4a", in: directory, added: base.addingTimeInterval(10))
    let duplicateNewer = entry("Notes.m4a", in: directory, added: base.addingTimeInterval(300))

    let sample = [older, middle, renamedFirst, duplicateOlder, duplicateNewer]
    #expect(
        LibrarySort.newestFirst.sorted(sample).map(\.id)
            == [duplicateNewer.id, renamedFirst.id, middle.id, duplicateOlder.id, older.id]
    )
    #expect(
        LibrarySort.oldestFirst.sorted(sample).map(\.id)
            == [older.id, duplicateOlder.id, middle.id, renamedFirst.id, duplicateNewer.id]
    )
    #expect(
        LibrarySort.name.sorted(sample).map(\.id)
            == [renamedFirst.id, older.id, middle.id, duplicateNewer.id, duplicateOlder.id]
    )

    let sameTimeA = entry("Same.m4a", in: directory, added: base)
    let sameTimeB = entry("Same.m4a", in: directory, added: base)
    let expectedByID = [sameTimeA, sameTimeB].sorted { $0.id.uuidString < $1.id.uuidString }
        .map(\.id)
    for order in [LibrarySort.newestFirst, .oldestFirst, .name] {
        #expect(order.sorted([sameTimeB, sameTimeA]).map(\.id) == expectedByID)
        #expect(order.sorted([sameTimeA, sameTimeB]).map(\.id) == expectedByID)
    }
}

@MainActor
@Test func libraryModelGroupsAndOrdersEntriesBySidebarFolders() throws {
    let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let law = UUID()
    let historyFolder = UUID()
    let unfiled = entry("Lecture 2.m4a", in: directory, added: base)
    let inHistoryTwo = entry("Lecture 10.m4a", in: directory, added: base.addingTimeInterval(60))
    var inLaw = entry("Zebra.m4a", in: directory, added: base.addingTimeInterval(120))
    inLaw.title = "Ethics"
    let inHistoryOne = entry("Notes.m4a", in: directory, added: base.addingTimeInterval(10))
    let orphaned = entry("Notes.m4a", in: directory, added: base.addingTimeInterval(300))

    let placements: [(Entry, UUID?)] = [
        (unfiled, nil),
        (inHistoryTwo, historyFolder),
        (inLaw, law),
        (inHistoryOne, historyFolder),
        (orphaned, UUID()),
    ]
    for (item, folderID) in placements {
        var copy = item
        copy.state = .finished
        copy.folderID = folderID
        try HistoryStore.write(copy, in: directory)
    }
    try HistoryStore.writeFolders(
        [
            TranscriptFolder(id: law, name: "Law"),
            TranscriptFolder(id: historyFolder, name: "History"),
        ],
        in: directory
    )

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    #expect(model.folders.map(\.name) == ["History", "Law"])
    model.layout.sort = .name
    #expect(model.entries(in: nil).map(\.id) == [unfiled.id, orphaned.id])
    #expect(model.entries(in: historyFolder).map(\.id) == [inHistoryTwo.id, inHistoryOne.id])
    #expect(model.entries(in: law).map(\.id) == [inLaw.id])

    model.layout.sort = .oldestFirst
    #expect(model.entries(in: historyFolder).map(\.id) == [inHistoryOne.id, inHistoryTwo.id])
    try model.renameFolder(law, to: "Arts")
    #expect(model.folders.map(\.name) == ["Arts", "History"])
}

@MainActor
@Test func subfoldersStayTwoLevelsDeepWithPerParentNamesAndColors() throws {
    let history = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: history) }
    let model = AppModel(history: history, defaults: MemoryDefaults())

    let biology = try model.createFolder(named: "Biology")
    let courseHistory = try model.createFolder(named: "History")
    let bioLectures = try model.createFolder(named: "Lectures", in: biology)
    let histLectures = try model.createFolder(named: "Lectures", in: courseHistory)

    #expect(model.canAddSubfolder(to: biology))
    #expect(!model.canAddSubfolder(to: bioLectures))
    #expect(try model.createFolder(named: "Lectures", in: biology) == bioLectures)
    let seminar = try model.createFolder(named: "Seminars", in: biology)
    #expect(throws: (any Error).self) { try model.renameFolder(seminar, to: "Lectures") }
    try model.removeFolder(seminar)
    #expect(throws: (any Error).self) { try model.createFolder(named: "Week 1", in: bioLectures) }
    #expect(model.holdsTranscripts(biology))
    #expect(model.folderPath(of: histLectures) == "History / Lectures")

    try model.removeFolder(bioLectures)
    #expect(!model.holdsTranscripts(biology))
    try model.setFolderColor(courseHistory, to: .orange)
    try model.setFolderColor(histLectures, to: .blue)

    let reloaded = AppModel(history: history, defaults: MemoryDefaults())
    #expect(reloaded.folder(courseHistory)?.color == .orange)
    #expect(reloaded.folder(histLectures)?.color == .blue)
    #expect(reloaded.subfolders(of: courseHistory).map(\.id) == [histLectures])

    let cycleA = UUID()
    let cycleB = UUID()
    let normalized = AppModel.sorted([
        TranscriptFolder(id: cycleA, name: "Zulu", parentID: cycleB),
        TranscriptFolder(id: cycleB, name: "Alpha", parentID: cycleA),
    ])
    #expect(normalized.map(\.name) == ["Alpha", "Zulu"])
    #expect(normalized.allSatisfy { $0.parentID == nil })
}

@MainActor
@Test func pinningKeepsFolderAndRemovesRowFromFolderList() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = TranscriptFolder(id: UUID(), name: "History")
    let first = entry("First.m4a", in: directory, added: .now)
    let second = entry("Second.m4a", in: directory, added: .now.addingTimeInterval(60))
    for var item in [first, second] {
        item.state = .finished
        item.folderID = folder.id
        try HistoryStore.write(item, in: directory)
    }
    try HistoryStore.writeFolders([folder], in: directory)

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    model.setPinned([first.id], to: true)
    #expect(model.pinnedEntries.map(\.id) == [first.id])
    #expect(model.entries(in: folder.id).map(\.id) == [second.id])
    #expect(model.entry(first.id)?.folderID == folder.id)
    #expect(model.hasPinnedEntries(in: folder.id))
    #expect(model.holdsTranscripts(folder.id))
    #expect(model.visibleEntryOrder.contains(first.id))

    model.layout.showsPinned = false
    #expect(!model.visibleEntryOrder.contains(first.id))
    model.layout.filter = .pinned
    #expect(model.visibleEntryOrder == [first.id])
    model.layout.filter = .all
    model.layout.showsPinned = true

    model.setPinned([first.id], to: false)
    await model.finishWrites()
    let reloaded = AppModel(history: directory, defaults: MemoryDefaults())
    #expect(reloaded.pinnedEntries.isEmpty)
    #expect(reloaded.entry(first.id)?.isPinned == nil)
    #expect(Set(reloaded.entries(in: folder.id).map(\.id)) == [first.id, second.id])

    var orphaned = entry("Orphaned.m4a", in: directory)
    orphaned.state = .finished
    orphaned.folderID = UUID()
    orphaned.isPinned = true
    try HistoryStore.write(orphaned, in: directory)
    let withOrphan = AppModel(history: directory, defaults: MemoryDefaults())
    #expect(withOrphan.hasPinnedEntries(in: nil))
}

@MainActor
@Test func collapsingSidebarSectionsHidesEntriesUntilRevealedOrFiltered() throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = TranscriptFolder(id: UUID(), name: "History")
    var filed = entry("Filed.m4a", in: directory)
    filed.state = .finished
    filed.folderID = folder.id
    var unfiled = entry("Unfiled.m4a", in: directory)
    unfiled.state = .finished
    for item in [filed, unfiled] { try HistoryStore.write(item, in: directory) }
    try HistoryStore.writeFolders([folder], in: directory)

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    model.setFolderExpanded(folder.id, to: true)
    #expect(model.visibleEntryOrder.contains(filed.id))
    model.setFolderExpanded(folder.id, to: false)
    #expect(!model.visibleEntryOrder.contains(filed.id))
    model.setFolderExpanded(folder.id, to: true)

    model.layout.showsFolders = false
    #expect(!model.visibleEntryOrder.contains(filed.id))
    model.revealFolder(folder.id)
    #expect(model.layout.showsFolders)
    #expect(model.visibleEntryOrder.contains(filed.id))

    model.layout.showsUnfiled = false
    #expect(!model.visibleEntryOrder.contains(unfiled.id))
    model.layout.searchQuery = "Unfiled"
    #expect(model.visibleEntryOrder.contains(unfiled.id))
    model.layout.searchQuery = ""

    model.layout.showsPinned = false
    model.setPinned([unfiled.id], to: true)
    #expect(model.layout.showsPinned)
}

@MainActor
@Test func flairsAndCustomTagsCombineWhileStatusStaysSingle() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    var item = entry("Lecture.m4a", in: directory)
    item.state = .finished
    try HistoryStore.write(item, in: directory)

    var second = entry("Seminar.m4a", in: directory, added: .now.addingTimeInterval(60))
    second.state = .finished
    try HistoryStore.write(second, in: directory)

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    model.toggleFlair(.todo, on: [item.id])
    model.toggleFlair(.urgent, on: [item.id])
    model.toggleFlair(.exam, on: [item.id])
    #expect(model.entry(item.id)?.flairs == [.urgent, .exam])

    model.addCustomTag(named: "Midterm", color: .blue, to: [item.id])
    model.addCustomTag(named: "Midterm", color: .purple, to: [second.id])
    model.addCustomTag(named: "Final", color: .green, to: [item.id])
    #expect(model.customFlairs.map(\.title) == ["Final", "Midterm"])

    let canonicalMidterm = try #require(model.customFlairs.first { $0.title == "Midterm" })
    model.toggleFlair(canonicalMidterm, on: [item.id])
    #expect(model.entry(item.id)?.flairs?.contains { $0.title == "Midterm" } == false)

    let orangeDot = TranscriptFlair(kind: nil, title: "", color: .orange)
    let greenDot = TranscriptFlair(kind: nil, title: "", color: .green)
    model.toggleFlair(orangeDot, on: [item.id])
    model.toggleFlair(greenDot, on: [item.id])
    #expect(model.entry(item.id)?.flairs?.contains(orangeDot) == false)
    #expect(model.entry(item.id)?.flairs?.contains(greenDot) == true)

    model.toggleFlair(.exam, on: [item.id])
    #expect(model.entry(item.id)?.flairs?.contains(.exam) == false)

    let savedFlairsEntry = try #require(model.entry(item.id))
    var pinnedRetrySource = savedFlairsEntry
    pinnedRetrySource.isPinned = true
    let retried = pinnedRetrySource.retrying()
    #expect(retried.flairs == savedFlairsEntry.flairs)
    #expect(retried.isPinned == true)

    model.clearFlairs(on: [item.id])
    await model.finishWrites()
    let reloaded = AppModel(history: directory, defaults: MemoryDefaults())
    #expect(reloaded.entry(item.id)?.flairs == nil)
}

@MainActor
@Test func librarySearchAndFiltersMatchNamesFoldersFlairsAndInheritedColors() throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bioID = UUID()
    let subID = UUID()
    let lawID = UUID()
    let bio = TranscriptFolder(id: bioID, name: "Biology", color: .green)
    let sub = TranscriptFolder(id: subID, name: "Cell Bio", parentID: bioID, color: .blue)
    let law = TranscriptFolder(id: lawID, name: "Law", color: .orange)
    try HistoryStore.writeFolders([bio, sub, law], in: directory)

    var cellular = entry("Respiration.m4a", in: directory)
    cellular.state = .finished
    cellular.folderID = subID
    cellular.isPinned = true
    cellular.flairs = [.urgent]

    var quiz = entry("Quiz Prep.m4a", in: directory)
    quiz.state = .finished
    quiz.folderID = bioID
    quiz.flairs = [.done, TranscriptFlair(kind: nil, title: "Midterm", color: .red)]

    var syllabus = entry("Syllabus.m4a", in: directory)
    syllabus.state = .finished
    syllabus.flairs = [.exam]

    for item in [cellular, quiz, syllabus] { try HistoryStore.write(item, in: directory) }

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    model.layout.filter = .color(.green)
    #expect(model.pinnedEntries.map(\.id) == [cellular.id])
    #expect(model.entries(in: bioID).map(\.id) == [quiz.id])
    #expect(!model.shouldShowFolder(lawID))

    model.layout.filter = .unreviewed
    #expect(model.entries(in: bioID).isEmpty)
    #expect(model.entries(in: nil).map(\.id) == [syllabus.id])

    model.layout.filter = .all
    model.layout.searchQuery = "Law"
    #expect(model.shouldShowFolder(lawID))
    model.layout.searchQuery = "Midterm"
    #expect(model.entries(in: bioID).map(\.id) == [quiz.id])
    #expect(model.pinnedEntries.isEmpty)
    model.layout.searchQuery = ""
    model.layout.filter = .tag("midterm")
    #expect(model.entries(in: bioID).map(\.id) == [quiz.id])
    #expect(model.pinnedEntries.isEmpty)

    let badName = "\(UUID().uuidString).json"
    try Data("damaged".utf8).write(to: directory.appending(path: badName))
    let filtered = AppModel(history: directory, defaults: MemoryDefaults())
    filtered.layout.filter = .pinned
    #expect(filtered.visibleUnidentifiedFiles.isEmpty)
    #expect(filtered.visibleEntryOrder == [cellular.id])
    filtered.layout.filter = .all
    #expect(filtered.visibleUnidentifiedFiles.count == 1)
    filtered.layout.searchQuery = "missing"
    #expect(filtered.visibleUnidentifiedFiles.isEmpty)
}

@MainActor
@Test func entrySupportsPinAndPresetFlairToggles() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }
    var item = entry("Lecture.m4a", in: directory)
    item.state = .finished
    try HistoryStore.write(item, in: directory)

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    model.setPinned([item.id], to: true)
    #expect(model.entry(item.id)?.isPinned == true)
    model.setPinned([item.id], to: false)
    #expect(model.entry(item.id)?.isPinned != true)

    for preset in TranscriptFlair.presets {
        model.toggleFlair(preset, on: [item.id])
        #expect(model.entry(item.id)?.flairs?.contains(preset) == true)
        model.toggleFlair(preset, on: [item.id])
        #expect(model.entry(item.id)?.flairs?.contains(preset) != true)
    }

    await model.finishWrites()
}

@MainActor
@Test func collapsedParentAutoExpandsForEmptyMatchingSubfolder() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    let bioID = UUID()
    let neuroID = UUID()
    let bio = TranscriptFolder(id: bioID, name: "Biology")
    let neuro = TranscriptFolder(id: neuroID, name: "Neurobiology", parentID: bioID)
    try HistoryStore.writeFolders([bio, neuro], in: directory)

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    #expect(!model.isFolderExpanded(bioID))

    model.layout.searchQuery = "Neurobiology"
    #expect(model.shouldShowFolder(neuroID))
    #expect(model.shouldShowFolder(bioID))
    #expect(model.isFolderExpanded(bioID))
    #expect(!model.isFolderExpanded(neuroID))
}

@MainActor
@Test func visibleSelectablePanesIncludesUnavailableRowsAndOpenNewEmitsRequest() throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    let bioID = UUID()
    let bio = TranscriptFolder(id: bioID, name: "Biology")
    try HistoryStore.writeFolders([bio], in: directory)

    var lecture = entry("Lecture.m4a", in: directory)
    lecture.state = .finished
    lecture.folderID = bioID
    try HistoryStore.write(lecture, in: directory)

    let futureID = UUID()
    let futureFile = directory.appending(path: "\(futureID.uuidString).json")
    try Data(#"{"id":"\#(futureID.uuidString)","requires":999,"name":"Future"}"#.utf8)
        .write(to: futureFile)
    let badID = UUID()
    try Data("damaged".utf8).write(to: directory.appending(path: "\(badID.uuidString).json"))

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    #expect(model.visibleSelectablePanes.contains(.unavailable(futureFile)))
    #expect(model.visibleSelectablePanes.contains(.unidentifiedFiles))
    #expect(!model.visibleSelectablePanes.contains(.entry(lecture.id)))

    model.revealFolder(bioID)
    #expect(model.visibleSelectablePanes.contains(.entry(lecture.id)))

    model.layout.searchQuery = "Biology"
    #expect(model.holdsTranscripts(bioID))

    model.pane = .new
    model.newTranscriptionRequest = nil
    model.chooseRecordings()
    let firstRequest = try #require(model.newTranscriptionRequest)
    model.manageGlossaries()
    let secondRequest = try #require(model.newTranscriptionRequest)
    #expect(firstRequest != secondRequest)
}

@Test func writeFoldersRollsBackWhenFolderDetailsWriteFails() throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    let original = TranscriptFolder(id: UUID(), name: "Original")
    try HistoryStore.writeFolders([original], in: directory)

    // Block writing folder-details.json so the second write fails after folders.json is rewritten.
    let blocker = directory.appending(path: "folder-details.json")
    try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

    let replacement = TranscriptFolder(id: UUID(), name: "Updated", color: .blue)
    #expect(throws: (any Error).self) {
        try HistoryStore.writeFolders([replacement], in: directory)
    }

    try FileManager.default.removeItem(at: blocker)
    let restored = try HistoryStore.folders(in: directory)
    #expect(restored == [original])
}

@MainActor
@Test func recoverEntrySyncsCustomTagCasingAndColorWithLiveTag() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    var live = entry("Live.m4a", in: directory)
    live.state = .finished
    let canonicalTag = TranscriptFlair(kind: nil, title: "Midterm", color: .blue)
    live.flairs = [canonicalTag]

    var deleted = entry("Deleted.m4a", in: directory)
    deleted.state = .finished
    deleted.removed = .now
    deleted.flairs = [TranscriptFlair(kind: nil, title: "midterm", color: .red)]

    try HistoryStore.write(live, in: directory)
    try HistoryStore.write(deleted, in: directory)

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    model.recoverEntry(deleted.id)
    await model.finishWrites()

    #expect(model.entry(deleted.id)?.flairs == [canonicalTag])
}

@MainActor
@Test func retryUnpinsFailedOriginalWhileKeepingRetryPinned() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    var failed = Entry(
        recording: directory.appending(path: "Lecture.m4a"),
        modelFile: "missing-test-model.bin", glossary: nil, skipsSilence: false, subtitles: false
    )
    failed.state = .failed("Stopped")
    failed.isPinned = true
    try HistoryStore.write(failed, in: directory)

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    model.retry(failed.id)
    await model.finishWrites()

    let retried = try #require(model.entries.first { $0.id != failed.id })
    #expect(retried.isPinned == true)
    #expect(model.entry(failed.id)?.isPinned != true)

    let reloaded = AppModel(history: directory, defaults: MemoryDefaults())
    #expect(reloaded.entry(retried.id)?.isPinned == true)
    #expect(reloaded.entry(failed.id)?.isPinned != true)
}

@MainActor
@Test func customFlairsStayCurrentWithoutNotifyingOnTranscriptEdits() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    var item = entry("Lecture.m4a", in: directory)
    item.state = .finished
    item.paragraphs = [Transcript.Paragraph(start: 0, text: "Bonjour")]
    try HistoryStore.write(item, in: directory)

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    model.addCustomTag(named: "Midterm", color: .blue, to: [item.id])
    await model.finishWrites()

    let reloaded = AppModel(history: directory, defaults: MemoryDefaults())
    #expect(reloaded.customFlairs.map(\.title) == ["Midterm"])

    func customFlairsNotified(_ mutate: () -> Void) -> Bool {
        let notified = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = reloaded.customFlairs
        } onChange: {
            notified.withLock { $0 = true }
        }
        mutate()
        return notified.withLock { $0 }
    }

    let notifiedOnEdit = customFlairsNotified {
        reloaded.updateEntry(item.id) { $0.paragraphs[0].text = "Bonjour edited" }
    }
    #expect(!notifiedOnEdit)

    let notifiedOnAdd = customFlairsNotified {
        reloaded.addCustomTag(named: "Exam", color: .green, to: [item.id])
    }
    #expect(notifiedOnAdd)
    #expect(reloaded.customFlairs.map(\.title) == ["Exam", "Midterm"])

    let notifiedOnColor = customFlairsNotified {
        reloaded.addCustomTag(named: "Midterm", color: .red, to: [item.id])
    }
    #expect(notifiedOnColor)
    #expect(reloaded.customFlairs.first { $0.title == "Midterm" }?.color == .red)

    let notifiedOnClear = customFlairsNotified {
        reloaded.clearFlairs(on: [item.id])
    }
    #expect(notifiedOnClear)
    #expect(reloaded.customFlairs.isEmpty)

    reloaded.addFolder()
    #expect(reloaded.folderRequest != nil)

    await reloaded.finishWrites()
}

@MainActor
@Test func collapsedFolderFlairsAggregateSubfoldersAndClearWhenExpanded() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    let biology = TranscriptFolder(id: UUID(), name: "Biology", color: .green)
    let lectures = TranscriptFolder(
        id: UUID(), name: "Lectures", parentID: biology.id, color: .blue)
    let emptyFolder = TranscriptFolder(id: UUID(), name: "Law", color: .purple)
    try HistoryStore.writeFolders([biology, lectures, emptyFolder], in: directory)

    let midterm = TranscriptFlair(title: "Midterm", color: .blue)
    let dot = TranscriptFlair(title: "", color: .yellow)

    var direct = entry("Overview.m4a", in: directory)
    direct.state = .finished
    direct.folderID = biology.id
    direct.flairs = [.done, dot]

    var nested = entry("Cell.m4a", in: directory)
    nested.state = .finished
    nested.folderID = lectures.id
    nested.flairs = [
        .todo, .exam, midterm, TranscriptFlair(title: "midterm", color: .red),
    ]

    var pinnedNested = entry("Review.m4a", in: directory)
    pinnedNested.state = .finished
    pinnedNested.folderID = lectures.id
    pinnedNested.isPinned = true
    pinnedNested.flairs = [.urgent, .exam]

    var deleted = entry("Old.m4a", in: directory)
    deleted.state = .finished
    deleted.folderID = emptyFolder.id
    deleted.removed = .now
    deleted.flairs = [.urgent]

    for item in [direct, nested, pinnedNested, deleted] {
        try HistoryStore.write(item, in: directory)
    }

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    #expect(model.collapsedFolderFlairs(in: emptyFolder.id).isEmpty)
    #expect(
        model.collapsedFolderFlairs(in: biology.id)
            == [.done, .todo, .urgent, .exam, midterm, dot]
    )

    model.layout.openFolders.insert(biology.id)
    #expect(model.collapsedFolderFlairs(in: biology.id).isEmpty)
    #expect(model.collapsedFolderFlairs(in: lectures.id) == [.todo, .urgent, .exam, midterm])

    model.layout.openFolders.insert(lectures.id)
    #expect(model.collapsedFolderFlairs(in: lectures.id).isEmpty)
    await model.finishWrites()
}

@MainActor
@Test func collapsedFolderFlairsStayQuietOnTextEditsAndRespectFilter() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    let course = TranscriptFolder(id: UUID(), name: "Physics")
    let pinnedOnly = TranscriptFolder(id: UUID(), name: "PinnedOnly")
    try HistoryStore.writeFolders([course, pinnedOnly], in: directory)

    var lecture = entry("Optics.m4a", in: directory)
    lecture.state = .finished
    lecture.folderID = course.id
    lecture.flairs = [.done]

    var pinnedDone = entry("SoloDone.m4a", in: directory)
    pinnedDone.state = .finished
    pinnedDone.folderID = pinnedOnly.id
    pinnedDone.isPinned = true
    pinnedDone.flairs = [.done]

    var pinnedUrgent = entry("SoloUrgent.m4a", in: directory)
    pinnedUrgent.state = .finished
    pinnedUrgent.folderID = pinnedOnly.id
    pinnedUrgent.isPinned = true
    pinnedUrgent.flairs = [.urgent]

    for item in [lecture, pinnedDone, pinnedUrgent] {
        try HistoryStore.write(item, in: directory)
    }

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    let notified = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
        _ = model.folderFlairs
    } onChange: {
        notified.withLock { $0 = true }
    }
    model.updateEntry(lecture.id) {
        $0.paragraphs = [Transcript.Paragraph(start: 0, text: "Edit")]
    }
    #expect(!notified.withLock { $0 })

    model.layout.searchQuery = "Optics"
    #expect(model.isFolderExpanded(course.id))
    #expect(model.collapsedFolderFlairs(in: course.id).isEmpty)

    model.layout.searchQuery = "PinnedOnly"
    #expect(model.shouldShowFolder(pinnedOnly.id))
    #expect(!model.isFolderExpanded(pinnedOnly.id))
    #expect(model.collapsedFolderFlairs(in: pinnedOnly.id) == [.done, .urgent])
    model.layout.searchQuery = ""

    #expect(FlairIcons.folderAccessibilityLabel("Law", collapsedFlairs: []) == "Law")
    let label = FlairIcons.folderAccessibilityLabel("History", collapsedFlairs: [.done, .urgent])
    #expect(label.contains("History") && label.contains("Done") && label.contains("Urgent"))
    await model.finishWrites()
}

@MainActor
@Test func collapsedFolderFlairsTrackLiveFlairMoveRemoveAndRecoverMutations() async throws {
    let directory = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: directory) }

    var first = entry("One.m4a", in: directory)
    first.state = .finished
    first.paragraphs = [Transcript.Paragraph(start: 0, text: "First")]
    var second = entry("Two.m4a", in: directory)
    second.state = .finished
    second.paragraphs = [Transcript.Paragraph(start: 0, text: "Second")]
    try HistoryStore.write(first, in: directory)
    try HistoryStore.write(second, in: directory)

    let model = AppModel(history: directory, defaults: MemoryDefaults())
    let source = try model.createFolder(named: "History")
    let sub = try model.createFolder(named: "Seminars", in: source)
    let dest = try model.createFolder(named: "Law")

    model.moveEntries([first.id, second.id], to: sub)
    model.toggleFlair(.urgent, on: [first.id, second.id])
    model.addCustomTag(named: "Midterm", color: .blue, to: [first.id])
    #expect(
        model.collapsedFolderFlairs(in: source)
            == [.urgent, TranscriptFlair(title: "Midterm", color: .blue)]
    )

    model.addCustomTag(named: "Midterm", color: .red, to: [second.id])
    #expect(
        model.collapsedFolderFlairs(in: sub)
            == [.urgent, TranscriptFlair(title: "Midterm", color: .red)]
    )

    model.moveEntry(second.id, to: dest)
    #expect(
        model.collapsedFolderFlairs(in: dest)
            == [.urgent, TranscriptFlair(title: "Midterm", color: .red)]
    )

    model.removeEntry(second.id)
    #expect(model.collapsedFolderFlairs(in: dest).isEmpty)
    model.recoverEntry(second.id)
    #expect(
        model.collapsedFolderFlairs(in: dest)
            == [.urgent, TranscriptFlair(title: "Midterm", color: .red)]
    )

    model.clearFlairs(on: [first.id, second.id])
    #expect(model.collapsedFolderFlairs(in: source).isEmpty)
    #expect(model.collapsedFolderFlairs(in: dest).isEmpty)
    await model.finishWrites()
}
