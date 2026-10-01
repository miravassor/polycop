// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

private func temporaryFolder() -> URL {
    URL.temporaryDirectory.appending(path: UUID().uuidString)
}

@Test func termsAreReadOnePerLineOrSeparatedByCommas() {
    let text = "Descartes\n  Pascal  \n\nMontaigne, Voltaire\nDescartes"
    #expect(Glossary.terms(in: text) == ["Descartes", "Pascal", "Montaigne", "Voltaire"])
}

/// A single-line prompt sentence is turned into its terms, everything after
/// "porte sur" and before the final full stop.
@Test func aPromptSentenceImportsAsTerms() {
    let sentence = "Ce cours de philosophie porte sur Descartes, doute méthodique, Pascal."
    #expect(Glossary.terms(in: sentence) == ["Descartes", "doute méthodique", "Pascal"])
}

/// Swift reads "\r\n" as a single Character, which a check for "\n" alone
/// would miss. A glossary saved on Windows used to become one long term.
@Test func windowsLineEndingsSeparateTerms() {
    #expect(
        Glossary.terms(in: "Descartes\r\nPascal\r\nMontaigne\r\n") == [
            "Descartes", "Pascal", "Montaigne",
        ])
}

/// Passed to C, a null character silently ends a string. Without splitting on
/// it here, terms after one would never reach the model or the token count.
@Test func aNullCharacterNeverEndsThePrompt() {
    let glossary = Glossary(name: "", text: "Descartes\u{0}\nPascal\u{0}Montaigne")
    #expect(glossary.prompt() == "Ce cours porte sur Descartes, Pascal, Montaigne.")
}

@Test func importingRefusesWhatIsNotAShortTextFile() throws {
    let folder = temporaryFolder()
    let elsewhere = temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let binary = elsewhere.appending(path: "Binaire.txt")
    try Data("Descartes\u{0}Pascal".utf8).write(to: binary)
    let large = elsewhere.appending(path: "Transcription.txt")
    try Data(repeating: 0x61, count: GlossaryStore.largestImport + 1).write(to: large)

    #expect(throws: GlossaryStore.ImportError.notText) {
        try GlossaryStore.importFile(binary, in: folder)
    }
    #expect(throws: GlossaryStore.ImportError.tooLarge) {
        try GlossaryStore.importFile(large, in: folder)
    }
    #expect(GlossaryStore.all(in: folder).isEmpty)
}

@Test func curlyApostrophesAreStraightened() {
    #expect(Glossary.terms(in: "l\u{2019}entendement") == ["l'entendement"])
}

/// Every term before a line holding "porte sur" used to be dropped, as if the
/// whole list were a single prompt sentence.
@Test func aListThatSaysPorteSurStaysAList() {
    let list = "Descartes\nLe cours porte sur Pascal\nMontaigne"
    #expect(Glossary.terms(in: list) == ["Descartes", "Le cours porte sur Pascal", "Montaigne"])
}

@Test func thePromptUsesTheSentenceForm() {
    let glossary = Glossary(name: "Philosophie", text: "Descartes\nPascal")
    #expect(glossary.prompt() == "Ce cours porte sur Descartes, Pascal.")
    #expect(glossary.prompt(in: "en") == "This lecture is about Descartes, Pascal.")
    #expect(Glossary(name: "Empty", text: "  \n ").prompt() == nil)
}

@Test func aGlossaryIsFoundAgainFromTheFolder() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    try GlossaryStore.save(Glossary(name: "Philosophie", text: "Descartes\nHéloïse"), in: folder)
    let found = GlossaryStore.all(in: folder)

    #expect(found.map(\.name) == ["Philosophie"])
    #expect(found.first?.terms == ["Descartes", "Héloïse"])
}

/// Importing never replaces a course, and a prompt sentence is stored as one
/// term per line.
@Test func importingNeverReplacesACourse() throws {
    let folder = temporaryFolder()
    let elsewhere = temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    try GlossaryStore.save(Glossary(name: "Philosophie", text: "Descartes"), in: folder)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let source = elsewhere.appending(path: "Philosophie.txt")
    try "Ce cours porte sur Pascal, Montaigne.".write(to: source, atomically: true, encoding: .utf8)

    let imported = try GlossaryStore.importFile(source, in: folder)

    #expect(imported.name == "Philosophie 2")
    #expect(imported.text == "Pascal\nMontaigne")
    #expect(GlossaryStore.all(in: folder).count == 2)
}

/// A text file saved on Windows is often not UTF-8, and its accents must survive.
@Test func aWindowsLatinFileImports() throws {
    let folder = temporaryFolder()
    let elsewhere = temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let source = elsewhere.appending(path: "Lettres.txt")
    let data = try #require("Héloïse\nœuvre".data(using: .windowsCP1252))
    try data.write(to: source)

    #expect(try GlossaryStore.importFile(source, in: folder).text == "Héloïse\nœuvre")
}

@Test func aCourseNameBecomesAFreeFileName() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    #expect(GlossaryStore.freeName(for: "L2/S3: Logique", in: folder) == "L2 S3  Logique")
    #expect(GlossaryStore.freeName(for: "   ", in: folder) == "Course")
    try GlossaryStore.save(Glossary(name: "Logique", text: ""), in: folder)
    #expect(GlossaryStore.freeName(for: "logique", in: folder) == "logique 2")
}

@Test func glossaryLimitAlsoAppliesToEditingAndFilesChangedOutsideTheApp() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let large = String(repeating: "é", count: GlossaryStore.largestImport)
    #expect(throws: GlossaryStore.ImportError.tooLarge) {
        try GlossaryStore.save(Glossary(name: "Too large", text: large), in: folder)
    }
    try large.write(to: folder.appending(path: "External.txt"), atomically: true, encoding: .utf8)
    #expect(GlossaryStore.all(in: folder).isEmpty)
    #expect(throws: CocoaError.self) {
        try GlossaryStore.save(Glossary(name: "../outside", text: "Pascal"), in: folder)
    }
}

@Test func utf16GlossaryKeepsFrenchAccents() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appending(path: "source.txt")
    let data = try #require("Héloïse\nœuvre".data(using: .utf16))
    try data.write(to: source)
    #expect(
        try GlossaryStore.importFile(source, in: folder.appending(path: "Glossaries")).text
            == "Héloïse\nœuvre")
}

@Test func englishPromptBecomesHotwordsWithoutItsInstruction() throws {
    let glossary = Glossary(name: "Synthetic", text: "Freud\nworking memory")
    #expect(Glossary.terms(in: try #require(glossary.prompt(in: "en"))) == glossary.terms)
    #expect(Glossary.terms(in: try #require(glossary.prompt(in: "fr"))) == glossary.terms)
}

@Test func aCourseRemembersAndForgetsItsCorrections() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = CourseCorrection(text: "bordéreux", replacement: "borderline")

    try CourseCorrections.remember(first, for: "Psychologie", in: folder)
    try CourseCorrections.remember(
        CourseCorrection(text: "Bordereux", replacement: "état limite"), for: "Psychologie",
        in: folder)
    #expect(
        CourseCorrections.all(for: "Psychologie", in: folder).map(\.replacement) == ["état limite"])

    try CourseCorrections.forget(
        CourseCorrection(text: "Bordereux", replacement: "état limite"), for: "Psychologie",
        in: folder)
    #expect(CourseCorrections.all(for: "Psychologie", in: folder).isEmpty)
}

@Test func courseCorrectionsBecomeTheUsersOwnCorrections() {
    var entry = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 4, text: "Le trouble bordéreux.")], partial: false)
    let original = entry.paragraphs

    entry.apply([CourseCorrection(text: "bordereux", replacement: "borderline")])

    #expect(entry.paragraphs.first?.text == "Le trouble borderline.")
    #expect(entry.isEdited)
    #expect(entry.original == original)
}

@Test func theCorrectionsFileIsNotAGlossary() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try GlossaryStore.save(Glossary(name: "Psychologie", text: "Freud"), in: folder)
    try CourseCorrections.remember(
        CourseCorrection(text: "Froid", replacement: "Freud"), for: "Psychologie", in: folder)

    #expect(GlossaryStore.all(in: folder).map(\.name) == ["Psychologie"])
}

/// A course's corrections do not stand in the way of putting credits back:
/// the paragraphs are rebuilt and the corrections applied again.
@MainActor
@Test func courseCorrectionsSurviveRebuildingTheParagraphs() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let course = "Psychologie"
    try CourseCorrections.remember(
        CourseCorrection(text: "bordereux", replacement: "borderline"), for: course, in: root)
    var entry = Entry(
        recording: root.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: Glossary(name: course, text: "borderline"), skipsSilence: false,
        subtitles: false)
    entry.publish(
        [
            Segment(start: 0, end: 30, text: " Sous-titrage Société Radio-Canada"),
            Segment(start: 31, end: 33, text: " Le trouble bordéreux."),
        ], partial: false)
    entry.courseCorrections = CourseCorrections.all(for: course, in: root)
    entry.publish(entry.decoded, partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: root)
    let reloaded = AppModel(history: root, glossaries: root)
    let stored = try #require(reloaded.entry(entry.id))
    #expect(stored.isEdited)
    #expect(stored.hasOnlyCourseCorrections)
    #expect(reloaded.canRebuildParagraphs(of: stored))

    reloaded.putBackCredits(entry.id)

    let restored = try #require(reloaded.entry(entry.id))
    #expect(restored.showsCredits)
    #expect(restored.paragraphs.map(\.text).joined().contains("borderline"))

    reloaded.edit(entry.id, paragraphAt: 0, text: "Une correction à la main.")
    #expect(!(try #require(reloaded.entry(entry.id))).hasOnlyCourseCorrections)
}

/// A remembered correction replaces whole words only: nobody reviews its
/// matches in the next transcripts.
@Test func courseCorrectionsLeaveOtherWordsAlone() {
    var entry = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 4, text: "Carl dit ca, et l'ego ca.")], partial: false)

    entry.apply([CourseCorrection(text: "ca", replacement: "ça")])

    #expect(entry.paragraphs.first?.text == "Carl dit ça, et l'ego ça.")
}

/// The corrections are read from disk once, and again after a change.
@MainActor
@Test func forgettingACorrectionIsSeenAtOnce() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let correction = CourseCorrection(text: "Froid", replacement: "Freud")
    try CourseCorrections.remember(correction, for: "Psychologie", in: root)
    let model = AppModel(history: root, glossaries: root)
    #expect(model.courseCorrections(forCourse: "Psychologie") == [correction])

    model.forget(correction, forCourse: "Psychologie")

    #expect(model.courseCorrections(forCourse: "Psychologie").isEmpty)
}

/// A correction that holds its own words leaves the places already correct,
/// and the list a transcript took is the one applied again, whatever the
/// course remembers later.
@Test func courseCorrectionsApplyOnceAndStayWithTheirTranscript() {
    var entry = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.courseCorrections = [CourseCorrection(text: "Freud", replacement: "Sigmund Freud")]
    entry.publish(
        [Segment(start: 0, end: 4, text: "Freud et Sigmund Freud, puis Froid.")], partial: false)

    #expect(entry.paragraphs.first?.text == "Sigmund Freud et Sigmund Freud, puis Froid.")
    #expect(entry.hasOnlyCourseCorrections)
}

/// Reverting drops the course corrections, so rebuilding the paragraphs,
/// as putting credits back does, keeps the text the user went back to.
@MainActor
@Test func revertingKeepsTheCourseCorrectionsOut() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var entry = Entry(
        recording: root.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.courseCorrections = [CourseCorrection(text: "Froid", replacement: "Freud")]
    entry.publish(
        [
            Segment(start: 0, end: 30, text: " Sous-titrage Société Radio-Canada"),
            Segment(start: 31, end: 33, text: " Froid parle."),
        ], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: root)
    let model = AppModel(history: root)

    model.revert(entry.id)
    let reverted = try #require(model.entry(entry.id))
    #expect(reverted.paragraphs.map(\.text).joined().contains("Froid"))
    var rebuilt = reverted
    let restored = rebuilt.putBackCredits()
    #expect(restored)
    #expect(rebuilt.paragraphs.map(\.text).joined().contains("Froid"))
}

/// A file that cannot be read is never written over.
@Test func anUnreadableCorrectionsFileIsKept() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "Psychologie.corrections.json")
    try Data("not json".utf8).write(to: file)

    #expect(throws: (any Error).self) {
        try CourseCorrections.remember(
            CourseCorrection(text: "Froid", replacement: "Freud"), for: "Psychologie", in: folder)
    }
    #expect(try Data(contentsOf: file) == Data("not json".utf8))
}

/// Glossaries made through the app are written to the folder it was given,
/// which a test keeps apart from the user's own.
@MainActor
@Test func theModelWritesGlossariesToItsOwnFolder() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "Logique.txt")
    try "Frege\nRussell".write(to: source, atomically: true, encoding: .utf8)
    let glossaries = root.appending(path: "Glossaries")
    let model = AppModel(history: root.appending(path: "History"), glossaries: glossaries)

    let created = try model.createGlossary(named: "Philosophie")
    let imported = try model.importGlossary(source)
    try model.saveGlossary(Glossary(name: created, text: "Descartes\nHéloïse"))

    #expect(Set(model.glossaries.map(\.name)) == [created, imported])
    let written = Set(GlossaryStore.all(in: glossaries).map(\.text))
    #expect(written == ["Descartes\nHéloïse", "Frege\nRussell"])
}

/// Undoing a revert brings back the course corrections it cleared, so they
/// count as course corrections again rather than as the user's own edits.
@MainActor
@Test func undoingARevertBringsBackTheCourseCorrections() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let corrections = [CourseCorrection(text: "des cartes", replacement: "Descartes")]
    var entry = Entry(
        recording: root.appending(path: "cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.courseCorrections = corrections
    entry.publish([Segment(start: 0, end: 4, text: "Nous lisons des cartes.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: root)
    let model = AppModel(history: root, glossaries: root)

    model.revert(entry.id)
    #expect(model.entry(entry.id)?.courseCorrections == [])
    model.undo(entry.id)

    let undone = try #require(model.entry(entry.id))
    #expect(undone.paragraphs.first?.text == "Nous lisons Descartes.")
    #expect(undone.courseCorrections == corrections)
    #expect(undone.hasOnlyCourseCorrections)
    #expect(model.canRebuildParagraphs(of: undone))
}
