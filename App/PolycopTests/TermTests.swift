// SPDX-License-Identifier: GPL-3.0-or-later

import CoreText
import Foundation
import Testing

@testable import Polycop

// Synthetic pages in the shape of French course material; no real lecture
// document is used, since the rules under test do not depend on one.

private let slide = """
    Le cours porte sur la psychanalyse. Jean Oury a fondé la clinique de La Borde.
    On lit Freud pour la première topique, et Piaget pour la période sensorimotrice.
    Les échelles utilisées sont le DSM-5 et la WAIS-IV.
    """

@Test func keepsNamesAndAcronymsAndRefusesOrdinaryWords() async {
    let terms = await Terms.candidates(in: [slide])

    #expect(terms.contains("Jean Oury"))
    #expect(terms.contains("Freud"))
    #expect(terms.contains("Piaget"))
    #expect(terms.contains("DSM-5"))
    #expect(terms.contains("WAIS-IV"))
    // Capitalised because the sentence opens, or because it is furniture.
    #expect(!terms.contains("Le"))
    #expect(!terms.contains("Les"))
    #expect(!terms.contains("Cours"))
}

@Test func refusesALoneWordCapitalisedOnlyBecauseItOpensASentence() async {
    let once = await Terms.candidates(in: ["Zorglub commence la phrase. On lit Wallon ensuite."])
    let twice = await Terms.candidates(in: ["Zorglub ouvre la phrase.", "Zorglub encore."])

    #expect(once.contains("Wallon"))
    #expect(!once.contains("Zorglub"))
    // Another page carrying it is support enough.
    #expect(twice.contains("Zorglub"))
}

@Test func believesALoneNameThePageRepeats() async {
    let bullets = "• Freud, première topique\n• Freud, seconde topique\n• Wallon"

    let terms = await Terms.candidates(in: [bullets])

    #expect(terms.contains("Freud"))
    // Named once, at the head of a bullet, where any word would be capitalised.
    #expect(!terms.contains("Wallon"))
}

@Test func dropsWhatEveryPageCarries() async {
    let pages = (1...6).map { "Université du Val, licence de psychologie\nGibello, page \($0)" }

    let terms = await Terms.candidates(in: pages)

    #expect(!terms.contains("Gibello"))
}

@Test func readsAcronymsOfAShoutingPageOnlyWhenMarkedOrAlreadyKnown() async {
    let page = "PSYCHOLOGIE DU DEVELOPPEMENT: LE MODELE DE GIBELLO, CIM-11, TSA"

    let plain = await Terms.candidates(in: [page])
    let known = await Terms.candidates(in: [page], attested: ["TSA"])

    #expect(plain.contains("CIM-11"))
    #expect(!plain.contains("TSA"))
    #expect(known.contains("TSA"))
}

@Test func keepsOneFormOfATermAndRanksTheStrongestLast() async {
    let pages = [
        "On lit Jean Piaget, puis Jean Piaget encore.",
        "Le stade décrit par Jean Piaget suit Wallon.",
    ]

    let terms = await Terms.candidates(in: pages)

    #expect(terms.contains("Jean Piaget"))
    #expect(!terms.contains("Piaget"))
    // whisper.cpp keeps the end of a prompt, so the most frequent term is last.
    #expect(terms.last == "Jean Piaget")
}

@Test func stopsAtThePromptBudget() async throws {
    let page = (1...400).map { "Le terme Xylo\($0) Machin\($0) est cité." }.joined(separator: " ")

    let terms = await Terms.candidates(in: [page], budget: 200)
    let candidate = Glossary(name: "", text: terms.joined(separator: "\n")).prompt()
    let prompt = try #require(candidate)

    #expect(!terms.isEmpty)
    #expect(Glossary.estimatedTokens(of: prompt) <= 200)
}

@Test func readsTheTextOfEveryPageOfAPDF() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "diapos.pdf")
    try write(["Jean Oury et la psychothérapie", "Le DSM-5 est cité"], to: file)

    let pages = try await Documents.pages(of: file)

    #expect(pages.count == 2)
    #expect(pages.first?.contains("Oury") == true)
}

@Test func readsARichTextFileAndRefusesWhatItCannotOpen() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let rich = folder.appending(path: "notes.rtf")
    let text = NSAttributedString(string: "Jean Oury, DSM-5")
    try text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])?
        .write(to: rich)
    let sound = folder.appending(path: "cours.wav")
    try Data([0, 1, 2]).write(to: sound)

    #expect(try await Documents.pages(of: rich).first?.contains("Oury") == true)
    await #expect(throws: DocumentError.self) { _ = try await Documents.pages(of: sound) }
}

@Test func cutsAPagelessDocumentIntoBlocks() {
    let text = (1...90).map { "ligne \($0)" }.joined(separator: "\n")

    #expect(Documents.blocks(of: text, lines: 40).count == 3)
    #expect(Documents.blocks(of: "\n\n").isEmpty)
}

/// A PDF of one line per page, as CoreGraphics writes it.
private func write(_ pages: [String], to file: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 400, height: 200)
    guard let context = CGContext(file as CFURL, mediaBox: &box, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    for page in pages {
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: page,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]
            ))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

@Test func namesAcrossSentencesAreNotJoined() async {
    let found = await Terms.candidates(in: [
        "Nous étudions Freud. Piaget intervient.",
        "Nous lisons Piaget. Freud répond.",
    ])
    #expect(found.contains("Freud"))
    #expect(found.contains("Piaget"))
    #expect(!found.contains("Freud Piaget"))
    #expect(!found.contains("Piaget Freud"))
}
