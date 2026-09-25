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
