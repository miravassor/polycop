// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

@Test func aCourseRemembersAndForgetsItsCorrections() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = CourseCorrection(text: "bordéreux", replacement: "borderline")

    try CourseCorrections.remember(first, for: "Psychologie", in: folder)
    try CourseCorrections.remember(
        CourseCorrection(text: "Bordereux", replacement: "état limite"), for: "Psychologie",
        in: folder)
    #expect(
        try CourseCorrections.all(for: "Psychologie", in: folder).map(\.replacement)
            == ["état limite"])

    try CourseCorrections.forget(
        CourseCorrection(text: "Bordereux", replacement: "état limite"), for: "Psychologie",
        in: folder)
    #expect(try CourseCorrections.all(for: "Psychologie", in: folder).isEmpty)
}

/// A place that already reads as the replacement is left alone however its
/// apostrophe is written, and applying a correction twice changes nothing.
@Test func aCorrectionAlreadyInPlaceIsLeftAloneWhateverItsApostrophe() {
    var entry = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish(
        [Segment(start: 0, end: 4, text: "L\u{2019}homme social et l'homme.")], partial: false)
    let correction = CourseCorrection(text: "l'homme", replacement: "l'homme social")

    entry.apply([correction])
    entry.apply([correction])

    #expect(entry.paragraphs.first?.text == "L\u{2019}homme social et l'homme social.")

    // A respelling still applies where the case differs.
    entry.apply([CourseCorrection(text: "l'homme social", replacement: "L'Homme social")])
    #expect(entry.paragraphs.first?.text == "L'Homme social et L'Homme social.")
}

/// A corrections file that cannot be read is reported, left as it is, and
/// read again once it can be, rather than remembered as no corrections.
@MainActor
@Test func unreadableCorrectionsAreReportedAndReadAgain() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let correction = CourseCorrection(text: "Froid", replacement: "Freud")
    try CourseCorrections.remember(correction, for: "Psychologie", in: root)
    let file = root.appending(path: "Psychologie.corrections.json")
    let stored = try Data(contentsOf: file)
    try Data("{ pas du JSON".utf8).write(to: file)
    let model = AppModel(history: root, glossaries: root)

    #expect(model.courseCorrections(forCourse: "Psychologie").isEmpty)
    #expect(model.failure?.contains("Psychologie") == true)
    #expect(try Data(contentsOf: file) == Data("{ pas du JSON".utf8))

    try stored.write(to: file)
    #expect(model.courseCorrections(forCourse: "Psychologie") == [correction])
}

/// Going back to the saved text after a failed save drops the failed write,
/// so retrying the saves does not bring back what was undone.
@MainActor
@Test func revertingAFailedGlossaryEditDropsTheFailedWrite() async throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let glossaries = root.appending(path: "Glossaries")
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: glossaries.path)
        try? FileManager.default.removeItem(at: root)
    }
    try GlossaryStore.save(Glossary(name: "Psychologie", text: "Freud"), in: glossaries)
    let model = AppModel(history: root.appending(path: "History"), glossaries: glossaries)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: glossaries.path)
    #expect(throws: (any Error).self) {
        try model.saveGlossary(Glossary(name: "Psychologie", text: "Jung"), loaded: "Freud")
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: glossaries.path)

    try model.saveGlossary(Glossary(name: "Psychologie", text: "Freud"), loaded: "Freud")
    await model.retrySavingHistory()

    #expect(model.unsavedGlossaries.isEmpty)
    #expect(GlossaryStore.all(in: glossaries).first?.text == "Freud")
}
