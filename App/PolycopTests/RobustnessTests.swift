// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// Damaged inputs, many of them, against the code that reads what a user
/// brings or types. A trap there, such as an index out of range or an
/// overflow, quits the app: each input must end in a result or a thrown error,
/// and the run survives only if none traps.
@Suite struct RobustnessTests {
    /// The same inputs on every run, so a failure can be replayed.
    struct Generator: RandomNumberGenerator {
        var state: UInt64

        // SplitMix64.
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    /// What the parsers treat specially, spliced in at random.
    static let pieces = [
        "-->", ":", "::", "[", "]", "[S01]", ",", ".", "\n", "\n\n", "\r\n", "WEBVTT", "NOTE",
        "99999999999999999999", "-1", "1e400", "nan", "00:59:59.999", "4:00:00", "\u{0}",
        "\u{feff}", "é", "e\u{301}", "👩‍👩‍👧", "{", "}", "\"", "null", "true", "[]", "{}", "?",
    ]

    static let rounds = 1_000

    /// A few insertions, deletions, byte changes or a cut, so most inputs stay
    /// close enough to the format to reach deep into its parser.
    static func damaged(_ text: String, using generator: inout Generator) -> Data {
        var bytes = Array(text.utf8)
        for _ in 0..<Int.random(in: 1...4, using: &generator) {
            let at = Int.random(in: 0...bytes.count, using: &generator)
            switch Int.random(in: 0..<4, using: &generator) {
            case 0:
                let piece = pieces[Int.random(in: pieces.indices, using: &generator)]
                bytes.insert(contentsOf: piece.utf8, at: at)
            case 1 where at < bytes.count:
                bytes.remove(at: at)
            case 2 where at < bytes.count:
                bytes[at] = UInt8.random(in: 0...255, using: &generator)
            case 3:
                bytes.removeSubrange(at...)
            default:
                break
            }
        }
        return Data(bytes)
    }

    @Test(arguments: [
        (
            "srt",
            "1\n00:00:01,500 --> 00:00:02,250\nBonjour.\n\n2\n00:00:03,000 --> 00:00:04,000\nSuite.\n"
        ),
        (
            "vtt",
            "WEBVTT\n\nNOTE a\n\n00:01.500 --> 00:02.250 align:start\nBonjour.\n\n00:03.000 --> 00:04.000\nSuite."
        ),
        ("txt", "[00:00:01.500 --> 00:00:02.250] Bonjour.\n[00:00:03] Suite.\nUne ligne."),
        ("txt", "Titre\n00:01 Bonjour.\n00:03,5 Suite.\n1:00:00 Fin."),
        ("txt", "[1.5][S01]Bonjour.[2.25]\n[3][S02]Suite.[4]"),
        (
            "json",
            #"{"transcription":[{"offsets":{"from":1500,"to":2250},"text":"Bonjour."},{"timestamps":{"from":"00:00:03,000","to":"00:00:04,000"},"text":"Suite."}]}"#
        ),
        (
            "json",
            #"{"text":"Bonjour à tous.","words":[{"word":"Bonjour","start":1.5,"end":2},{"word":"à","start":2,"end":2.2},{"word":"tous","start":2.2,"end":2.5}]}"#
        ),
        (
            "json",
            #"{"sample_rate":48000,"speaker_turns":[{"start_sample":72000,"end_sample":108000,"speaker_id":"S01","text":"Bonjour."}]}"#
        ),
    ])
    func importingDamagedTranscriptsNeverTraps(suffix: String, text: String) {
        var generator = Generator(state: UInt64(truncatingIfNeeded: text.utf8.count))
        let recording = URL(filePath: "/tmp/synthetic.wav")
        for _ in 0..<Self.rounds {
            let data = Self.damaged(text, using: &generator)
            guard let parsed = try? TranscriptImport.parse(data, extension: suffix) else {
                continue
            }
            // What is accepted must also become an entry, or be refused.
            _ = try? parsed.entry(recording: recording, duration: 60, source: "Test.\(suffix)")
        }
    }

    /// Whatever is typed, every word placed lies inside the text, since the
    /// editor styles those ranges and a range past the end throws.
    @Test func placedWordsStayInsideAnyTypedText() {
        var generator = Generator(state: 7)
        let said = "Bonjour à tous, l'encodage d'un signal numérique commence ici ?"
        let words = said.split(separator: " ").enumerated().map { index, text in
            Segment.Word(
                text: " " + text, start: Double(index), end: Double(index) + 0.8,
                confidence: 0.9)
        }
        for _ in 0..<Self.rounds {
            let text = String(decoding: Self.damaged(said, using: &generator), as: UTF8.self)
            let length = (text as NSString).length
            let placed = WordLayout.place(words, in: text)
            let inside = placed.allSatisfy {
                $0.range.location >= 0 && NSMaxRange($0.range) <= length && $0.start.isFinite
            }
            #expect(inside, "\(text)")
            for index in [0, length / 2, length] {
                #expect(WordLayout.time(at: index, in: placed, from: 0).isFinite)
            }
        }
    }
}
