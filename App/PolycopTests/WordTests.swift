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

    // A corrected word is no longer found, and the words after it still are.
    let corrected = WordLayout.place(words, in: "Le trouble borderline est connu.")
    #expect(corrected.map(\.start) == [0, 0.2, 1.2, 1.4])
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
/// place: the "de la" deleted is not matched to the one further on.
@Test func deletedWordsLeaveTheRestInPlace() {
    let spoken = "Le patient de la clinique présente un trouble de la personnalité."
    let words = spoken.split(separator: " ").enumerated().map {
        Segment.Word(text: String($1), start: Double($0), end: Double($0) + 0.9)
    }
    let text = "Le patient présente un trouble de la personnalité."
    let placed = WordLayout.place(words, in: text)
    let string = text as NSString

    #expect(placed.map(\.start) == [0, 1, 5, 6, 7, 8, 9, 10])
    #expect(WordLayout.playing(placed, at: 5.5) == string.range(of: "présente"))
    #expect(WordLayout.playing(placed, at: 10.2) == string.range(of: "personnalité"))
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

/// A paragraph rewritten from end to end finds none of its words.
@Test func aRewrittenParagraphPlacesNoWord() {
    let words = (0..<120).map { Segment.Word(text: "mot\($0)", start: Double($0), end: Double($0)) }
    #expect(WordLayout.place(words, in: "Passage inaudible, à réécouter.").isEmpty)
}
