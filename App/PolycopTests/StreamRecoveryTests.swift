// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// A Voxtral stream silent for 64 steps starts again: from its last text in
/// the middle of speech, without replaying in a real silence, and never in
/// the silence pushed after the window.
@Test func aSilentVoxtralStreamStartsAgainFromItsLastText() {
    let silence = AudioCppEngine.voxtralSilentSteps * AudioCppEngine.voxtralStep
    let audio = 300 * 16_000
    func restart(heard: Int, lastText: Int, replayedTo: Int = 0, pushed: Int? = nil) -> Int? {
        AudioCppEngine.voxtralRestart(
            heard: heard, lastText: lastText, replayedTo: replayedTo,
            pushed: pushed ?? heard + AudioCppEngine.voxtralDelay, audioCount: audio)
    }
    // Text keeps coming.
    #expect(restart(heard: 640_000, lastText: 640_000 - silence + 1) == nil)
    // Stalled in the middle of speech: read again from the last text.
    #expect(restart(heard: 640_000, lastText: 640_000 - silence) == 640_000 - silence)
    // Still nothing after that: on from where audio had gone, without replaying.
    let pushed = 640_000 + silence + AudioCppEngine.voxtralDelay
    #expect(
        restart(heard: 640_000 + silence, lastText: 640_000, replayedTo: pushed, pushed: pushed)
            == pushed)
    // In the flush after the window's own audio.
    #expect(restart(heard: audio, lastText: audio - silence, pushed: audio + 1) == nil)
}

/// A MOSS window cut by its token limit is read again from its last
/// finished passage, unless that leaves less than a second either side.
@Test func aCutMossWindowIsReadAgainFromItsLastPassage() {
    let window = 160_000..<4_960_000
    #expect(AudioCppEngine.rest(of: window, after: 100) == 1_600_000..<4_960_000)
    #expect(AudioCppEngine.rest(of: window, after: nil) == nil)
    #expect(AudioCppEngine.rest(of: window, after: 10.5) == nil)
    #expect(AudioCppEngine.rest(of: window, after: 309.5) == nil)
}

/// A minute or more without text is a stretch to listen to, at the start, in
/// the middle and at the end; shorter pauses and overlapping segments are not.
@Test func stretchesWithoutTextLastAMinuteOrMore() {
    let segments = [
        Segment(start: 61, end: 100, text: "Bonjour."),
        Segment(start: 90, end: 130, text: "Nous commençons."),
        Segment(start: 189, end: 200, text: "Voici le plan."),
        Segment(start: 259, end: 300, text: "Fin."),
    ]
    #expect(TextGaps.stretches(in: segments, lasting: 400) == [0...61, 300...400])
    #expect(TextGaps.stretches(in: segments, lasting: nil) == [0...61])
    #expect(TextGaps.stretches(in: [], lasting: 30).isEmpty)
}

/// A Voxtral window stopped part way keeps the spans it had read to their
/// end, without the word being read last.
@Test func aStoppedVoxtralWindowKeepsTheSpansItFinished() {
    let streamed = Array(" Bonjour à tous. Nous commen".utf8)
    let first = " Bonjour à tous.".utf8.count
    let segments = AudioCppEngine.finishedSpans(
        of: streamed, marks: [(480_000, first), (960_000, streamed.count)], from: 60)
    #expect(
        segments == [
            Segment(start: 60, end: 90, text: "Bonjour à tous."),
            Segment(start: 90, end: 120, text: "Nous"),
        ])
    #expect(AudioCppEngine.finishedSpans(of: streamed, marks: [], from: 0).isEmpty)
}
