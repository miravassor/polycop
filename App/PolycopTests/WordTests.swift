// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// Whisper's tokens are pieces of words; a new word starts with a space, and
/// punctuation stays with the word before it.
@Test func tokensJoinIntoWordsWithTheirMeanConfidence() {
    let tokens = [
        WhisperEngine.Token(bytes: Array(" Bon".utf8), probability: 0.9, start: 0, end: 20),
        WhisperEngine.Token(bytes: Array("jour".utf8), probability: 0.7, start: 20, end: 40),
        WhisperEngine.Token(bytes: Array(",".utf8), probability: 0.8, start: 40, end: 42),
        WhisperEngine.Token(bytes: Array(" à".utf8), probability: 0.3, start: 50, end: 60),
    ]

    let words = WhisperEngine.words(from: tokens)

    #expect(words.map(\.text) == ["Bonjour,", "à"])
    #expect(words.map(\.start) == [0, 0.5])
    #expect(words.map(\.end) == [0.42, 0.6])
    #expect(abs((words.first?.confidence ?? 0) - 0.8) < 0.0001)
    #expect(words.last?.confidence == 0.3)
}

/// A character split between two tokens is decoded with the whole word.
@Test func aCharacterSplitBetweenTokensStaysWhole() {
    let heart = Array(" cœur".utf8)
    let tokens = [
        WhisperEngine.Token(bytes: Array(heart[..<3]), probability: 1, start: 0, end: 10),
        WhisperEngine.Token(bytes: Array(heart[3...]), probability: 1, start: 10, end: 20),
    ]
    #expect(WhisperEngine.words(from: tokens).map(\.text) == ["cœur"])
}

@Test func wordsAreFoundInTheirParagraphInOrder() {
    let words = [
        Segment.Word(text: "Le", start: 0, end: 0.2),
        Segment.Word(text: "trouble", start: 0.2, end: 0.6, confidence: 0.9),
        Segment.Word(text: "bordéreux", start: 0.6, end: 1.2, confidence: 0.2),
        Segment.Word(text: "est", start: 1.2, end: 1.4),
        Segment.Word(text: "connu.", start: 1.4, end: 2),
    ]

    let written = WordLayout.place(words, in: "Le trouble bordéreux est connu.")
    #expect(written.count == 5)
    let uncertain = written.filter(\.isUncertain).map(\.start)
    #expect(uncertain == [0.6])

    // A corrected word takes the time of the word it replaced, is no longer
    // uncertain, and the words after it are still found.
    let text = "Le trouble borderline est connu."
    let corrected = WordLayout.place(words, in: text)
    #expect(corrected.map(\.start) == [0, 0.2, 0.6, 1.2, 1.4])
    #expect(corrected[2].range == (text as NSString).range(of: "borderline"))
    let stillUncertain = corrected.contains { $0.isUncertain }
    #expect(!stillUncertain)
}

/// The words after a long insertion are found again, and a short word is
/// never found inside another: "a" is not placed in "la".
@Test func wordsAreFoundAgainAfterALongInsertion() {
    let words = [
        Segment.Word(text: "Freud", start: 0, end: 0.5),
        Segment.Word(text: "a", start: 0.5, end: 0.6),
        Segment.Word(text: "écrit", start: 0.6, end: 1),
        Segment.Word(text: "tard.", start: 1, end: 1.5),
    ]
    let text = "Freud, le fondateur de la psychanalyse selon la plupart des auteurs, a écrit tard."
    let placed = WordLayout.place(words, in: text)

    #expect(placed.map(\.start) == [0, 0.5, 0.6, 1])
    let standalone = (text as NSString).range(of: " a ").location + 1
    #expect(placed[1].range == NSRange(location: standalone, length: 1))
}

/// Deleting words, common ones among them, keeps the words after them in
/// place: the "de la" deleted is not matched to the one further on. While the
/// words deleted are heard, no word is lit, unless they are as brief as a
/// hesitation.
@Test func deletedWordsLeaveTheRestInPlace() {
    let spoken = "Le patient de la clinique présente euh un trouble de la personnalité."
    let words = spoken.split(separator: " ").enumerated().map {
        Segment.Word(text: String($1), start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.45)
    }
    let text = "Le patient présente un trouble de la personnalité."
    let placed = WordLayout.place(words, in: text)
    let string = text as NSString

    #expect(
        placed.filter { $0.range.length > 0 }.map(\.start) == [0, 0.5, 2.5, 3.5, 4, 4.5, 5, 5.5])
    #expect(WordLayout.playing(placed, at: 1.2)?.length == 0)
    #expect(WordLayout.playing(placed, at: 2.7) == string.range(of: "présente"))
    #expect(WordLayout.playing(placed, at: 3.2) == string.range(of: "présente"))
    #expect(WordLayout.playing(placed, at: 5.6) == string.range(of: "personnalité"))

    // A click where deleted words were plays the first word shown, not them.
    let opening = WordLayout.place(words, in: "Présente un trouble de la personnalité.")
    #expect(WordLayout.time(at: 0, in: opening, from: 0) == 2.5)
}

/// Words written in place of others take their time, spread over it, so the
/// word lit goes on through a rewritten passage.
@Test func rewrittenWordsTakeTheTimeOfThoseTheyReplace() {
    let spoken =
        "on parle de la mémoire de travail c'est-à-dire la capacité à garder une information"
    let words = spoken.split(separator: " ").enumerated().map {
        Segment.Word(text: String($1), start: Double($0), end: Double($0) + 0.9)
    }
    let text = "On parle de la mémoire de travail, soit retenir une information."
    let placed = WordLayout.place(words, in: text)
    let string = text as NSString

    #expect(WordLayout.playing(placed, at: 7.5) == string.range(of: "soit"))
    #expect(WordLayout.playing(placed, at: 10.5) == string.range(of: "retenir"))
    #expect(WordLayout.playing(placed, at: 12.5) == string.range(of: "une"))
}

/// Words an aligner split and stripped are found inside the written ones, as
/// Qwen3's aligner times "L'encodage" as "L" and "encodage"; a word written
/// with its apostrophe spans it whole, and punctuation alone is not placed.
@Test func splitWordsAreFoundInsideTheWrittenOnes() {
    let text = "L'encodage, d'abord ?"
    let string = text as NSString
    let aligner = [
        Segment.Word(text: "L", start: 1.8, end: 1.9),
        Segment.Word(text: "encodage", start: 1.9, end: 2.5),
        Segment.Word(text: "d", start: 2.5, end: 2.6),
        Segment.Word(text: "abord", start: 2.6, end: 3.1),
    ]
    let whisper = [
        Segment.Word(text: "L'encodage,", start: 1.8, end: 2.5),
        Segment.Word(text: "d'abord", start: 2.5, end: 3.1),
        Segment.Word(text: "?", start: 3.1, end: 3.2),
    ]

    #expect(
        WordLayout.place(aligner, in: text).map(\.range) == [
            NSRange(location: 0, length: 1), string.range(of: "encodage"),
            NSRange(location: string.range(of: "d'abord").location, length: 1),
            string.range(of: "abord"),
        ])
    #expect(
        WordLayout.place(whisper, in: text).map(\.range) == [
            string.range(of: "L'encodage"), string.range(of: "d'abord"),
        ])
}

/// A click in text typed but not handed over yet finds where it stood in the
/// text the words were placed in, whether typing added or removed words.
@Test func aClickDuringTypingFindsItsPlaceInThePlacedText() {
    let placed = "Le trouble est connu."
    let typed = "Le trouble limite est connu."
    let connu = (placed as NSString).range(of: "connu").location
    let typedConnu = (typed as NSString).range(of: "connu").location

    #expect(WordLayout.index(3, in: typed, placedIn: placed) == 3)
    #expect(WordLayout.index(typedConnu, in: typed, placedIn: placed) == connu)
    // Inside the typed word, the click stands where typing began.
    #expect(WordLayout.index(13, in: typed, placedIn: placed) == 11)
    #expect(WordLayout.index(connu, in: placed, placedIn: typed) == typedConnu)
}

/// A click on text written since plays from between the words still found
/// around it, so a paragraph rewritten at length still plays from a click.
@Test func aClickInRewrittenTextPlaysFromBetweenTheWordsAround() {
    let words = [
        Segment.Word(text: "Le", start: 10, end: 10.2),
        Segment.Word(text: "trouble", start: 10.2, end: 10.6),
        Segment.Word(text: "bordéreux", start: 10.6, end: 11.2),
        Segment.Word(text: "est", start: 11.2, end: 11.4),
        Segment.Word(text: "connu.", start: 11.4, end: 12),
    ]
    let text = "Nouvelle phrase. Le trouble limite, souvent appelé ainsi, est connu."
    let placed = WordLayout.place(words, in: text)
    let string = text as NSString

    #expect(WordLayout.time(at: string.range(of: "trouble").location, in: placed, from: 9) == 10.2)
    #expect(WordLayout.time(at: string.range(of: "phrase").location, in: placed, from: 9) < 10)
    #expect(WordLayout.time(at: string.range(of: "phrase").location, in: placed, from: 9) > 9)
    let rewritten = WordLayout.time(at: string.range(of: "appelé").location, in: placed, from: 9)
    #expect(rewritten > 10.2 && rewritten < 11.2)
    #expect(WordLayout.time(at: string.length, in: placed, from: 9) == 11.4)
    #expect(WordLayout.time(at: 3, in: [], from: 9) == 9)
}

@Test func theWordPlayingIsTheLastOneStarted() {
    let placed = WordLayout.place(
        [
            Segment.Word(text: "Bonjour", start: 1, end: 1.5),
            Segment.Word(text: "à", start: 1.5, end: 1.6),
        ], in: "Bonjour à tous")
    #expect(WordLayout.playing(placed, at: 0.5) == nil)
    #expect(WordLayout.playing(placed, at: 1.2) == NSRange(location: 0, length: 7))
    #expect(WordLayout.playing(placed, at: 1.55) == NSRange(location: 8, length: 1))
}

@Test func wordsGoToTheParagraphThatHoldsTheirStart() {
    let segments = [
        Segment(
            start: 0, end: 2, text: "Un deux", words: [.init(text: "Un", start: 0, end: 1)]),
        Segment(
            start: 10, end: 12, text: "Trois", words: [.init(text: "Trois", start: 10, end: 12)]),
    ]
    let paragraphs = [
        Transcript.Paragraph(start: 0, text: "Un deux"),
        Transcript.Paragraph(start: 9_000, text: "Trois"),
    ]
    #expect(
        WordLayout.grouped(segments, into: paragraphs).map { $0.map(\.text) } == [
            ["Un"], ["Trois"],
        ])
}

/// Words move with their segment, are dropped with a new text, and records
/// written before words were kept still load.
@Test func segmentsKeepTheirWordsInStep() throws {
    let segment = Segment(
        start: 1, end: 2, text: "Bonjour", words: [.init(text: "Bonjour", start: 1, end: 2)])
    #expect(segment.shifted(by: 10).words?.first?.start == 11)
    #expect(segment.replacing(text: "Bonsoir").words == nil)

    let older = Data(#"{"start": 1, "end": 2, "text": "Bonjour"}"#.utf8)
    #expect(try JSONDecoder().decode(Segment.self, from: older).words == nil)
}

/// A paragraph rewritten from end to end finds none of its words, and its
/// own words share the time the paragraph was said in.
@Test func aRewrittenParagraphSpreadsItsWordsOverItsTime() {
    let words = (0..<120).map { Segment.Word(text: "mot\($0)", start: Double($0), end: Double($0)) }
    let placed = WordLayout.place(words, in: "Passage inaudible, à réécouter.")
    #expect(placed.map(\.start) == [0, 29.75, 59.5, 89.25])
    #expect(placed.allSatisfy { $0.confidence == nil })
}
