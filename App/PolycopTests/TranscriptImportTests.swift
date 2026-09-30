// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Testing

@testable import Polycop

@Suite struct TranscriptImportTests {
    @Test(arguments: [
        ("srt", "1\n00:00:01,500 --> 00:00:02,250\nBonjour.\n"),
        ("vtt", "WEBVTT\n\ncue-1\n00:01.500 --> 00:02.250 align:start\nBonjour.\n"),
        ("txt", "[00:00:01.500 --> 00:00:02.250] Bonjour."),
        ("txt", "[1.5][S01]Bonjour.[2.25]"),
        ("json", #"{"transcription":[{"offsets":{"from":1500,"to":2250},"text":"Bonjour."}]}"#),
        ("json", #"{"segments":[{"start":1.5,"end":2.25,"text":"Bonjour."}]}"#),
        ("json", #"[{"start_sample":24000,"end_sample":36000,"text":"Bonjour."}]"#),
        (
            "json",
            #"{"sample_rate":48000,"segments":[{"start_sample":72000,"end_sample":108000,"text":"Bonjour."}]}"#
        ),
        (
            "json",
            #"{"speaker_turns":[{"start_sample":24000,"end_sample":36000,"speaker_id":"S01","text":"Bonjour."}]}"#
        ),
    ])
    func formatsPreserveTheirUnits(suffix: String, text: String) throws {
        let parsed = try TranscriptImport.parse(Data(text.utf8), extension: suffix)
        #expect(parsed.cues.count == 1)
        #expect(parsed.cues.first?.start == 1.5)
        #expect(parsed.cues.first?.end == 2.25)
        #expect(parsed.cues.first?.text == "Bonjour.")
    }

    /// Older subtitle tools save French in Windows Latin, where an accented
    /// letter is not valid UTF-8.
    @Test(arguments: [
        ("srt", "1\n00:00:01,500 --> 00:00:02,250\nL'été, déjà.\n"),
        ("vtt", "WEBVTT\n\n00:01.500 --> 00:02.250\nL'été, déjà.\n"),
        ("txt", "[00:00:01.500 --> 00:00:02.250] L'été, déjà."),
    ])
    func windowsLatinTextIsRead(suffix: String, text: String) throws {
        let data = try #require(text.data(using: .windowsCP1252))
        #expect(String(data: data, encoding: .utf8) == nil)
        let parsed = try TranscriptImport.parse(data, extension: suffix)
        #expect(parsed.cues.map(\.text) == ["L'été, déjà."])
    }

    @Test func polycopTextPreservesParagraphsWithoutInventingSubtitleTimings() throws {
        let text =
            "[00:00:01] Merci d'avoir regardé cette vidéo.\nUne deuxième ligne.\n\n[00:00:03] Suite.\n\n"
        let parsed = try TranscriptImport.parse(Data(text.utf8), extension: "TXT")
        let entry = try parsed.entry(
            recording: URL(filePath: "/tmp/synthetic.wav"), duration: 5, source: "Course.txt")
        #expect(entry.paragraphs.count == 2)
        #expect(
            entry.paragraphs[0].text == "Merci d'avoir regardé cette vidéo.\nUne deuxième ligne.")
        #expect(entry.decoded.map(\.end) == [3, 5])
        #expect(entry.hiddenCredits.isEmpty)
        #expect(entry.original == entry.paragraphs)
        #expect(!entry.timesSentences)
        #expect(entry.importSource == "Course.txt")
        #expect(entry.hasValidHistory)
    }

    /// Recorder apps write bare times under a title and a date, in text or in
    /// a Word document; the lines before the first time are left out.
    @Test(arguments: ["txt", "docx"])
    func recorderExportsImportWithBareTimes(suffix: String) throws {
        let text =
            "Cours synthétique\n2026-01-05 10:00:00\n00:00:00 Bonjour à tous.\n00:00:16 On commence."
        let data =
            suffix == "docx"
            ? try NSAttributedString(string: text).data(
                from: NSRange(location: 0, length: (text as NSString).length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            : Data(text.utf8)

        let parsed = try TranscriptImport.parse(data, extension: suffix)

        #expect(parsed.cues.map(\.start) == [0, 16])
        #expect(parsed.cues.map(\.text) == ["Bonjour à tous.", "On commence."])
    }

    /// Once the times are bracketed, a line of text that opens on a time stays
    /// text, and a bare time can sit alone above its words.
    @Test func theFirstTimeDecidesTheStyle() throws {
        let bracketed = try TranscriptImport.parse(
            Data("[00:00:01] On se retrouve\n12:00 dans la salle B.".utf8), extension: "txt")
        #expect(bracketed.cues.map(\.text) == ["On se retrouve\n12:00 dans la salle B."])

        let alone = try TranscriptImport.parse(
            Data("00:00:01\nBonjour.\n00:00:05\nSuite.".utf8), extension: "txt")
        #expect(alone.cues.map(\.start) == [1, 5])
        #expect(alone.cues.map(\.text) == ["Bonjour.", "Suite."])
    }

    @Test func wordAlignmentKeepsTheFullTextAndPunctuation() throws {
        let json =
            #"{"text":"Bonjour, monde !","words":[{"word":"Bonjour","start_sample":0,"end_sample":8000},{"word":"monde","start_sample":8000,"end_sample":16000}]}"#
        let parsed = try TranscriptImport.parse(Data(json.utf8), extension: "json")
        #expect(parsed.cues.map(\.text) == ["Bonjour, monde !"])
        #expect(parsed.cues.first?.end == 1)
    }

    @Test func subtitlesAcceptWhitespaceBetweenCuesAndKeepLiteralMarkup() throws {
        let text =
            "1\r\n00:00:00,000 --> 00:00:01,000\r\n<i>Bonjour</i>\r\n \r\n\r\n2\r\n00:00:01,000 --> 00:00:02,000\r\nSuite\r\n"
        let parsed = try TranscriptImport.parse(Data(text.utf8), extension: "srt")
        #expect(parsed.cues.map(\.text) == ["<i>Bonjour</i>", "Suite"])
    }

    @Test(arguments: [
        ("txt", "Plain text has no alignment."),
        ("txt", "[00:99:00] Invalid."),
        ("txt", "[00:00:02] Second.\n[00:00:01] First."),
        ("srt", "1\n00:00:02,000 --> 00:00:01,000\nBackwards."),
        ("srt", "1\n00:00:00,000 --> 00:00:01,000\nValid.\n\nBroken cue."),
        ("txt", "[0.0][S01]Valid.[1.0] trailing untimed text"),
        ("json", #"{"segments":[{"start":true,"end":1,"text":"Invalid."}]}"#),
        ("json", #"{"segments":[{"start":0,"end":1e300,"text":"Invalid."}]}"#),
        ("json", #"{"segments":[{"start_sample":0,"end_sample":100}]}"#),
        (
            "json",
            #"{"text":"Different text","words":[{"word":"Bonjour","start_sample":0,"end_sample":8000}]}"#
        ),
    ])
    func malformedInputsAreRefusedWhole(suffix: String, text: String) {
        #expect(throws: (any Error).self) {
            try TranscriptImport.parse(Data(text.utf8), extension: suffix)
        }
    }

    @Test(arguments: [
        #"{"text":"Bonjour monde.","words":[{"word":"Bonjour","start":0,"end":-1},{"word":"monde","start":1,"end":2}]}"#,
        #"{"text":"Bonjour monde.","words":[{"word":"Bonjour","start":1,"end":2},{"word":"monde","start":0,"end":3}]}"#,
    ])
    func groupingCannotHideInvalidWordTimes(_ json: String) {
        #expect(throws: TranscriptImport.Failure.self) {
            try TranscriptImport.parse(Data(json.utf8), extension: "json")
        }
    }

    @Test func multilineParagraphKeepsEveryLine() throws {
        let lines = (0..<10_000).map { "Line \($0)." }
        let text = "[00:00:00] " + lines.joined(separator: "\n")
        let parsed = try TranscriptImport.parse(Data(text.utf8), extension: "txt")
        #expect(parsed.cues.count == 1)
        #expect(parsed.cues[0].text == lines.joined(separator: "\n"))
    }

    @Test func mismatchedAudioIsRefusedWithoutShiftingText() throws {
        let parsed = try TranscriptImport.parse(Data("[00:00:10] Bonjour.".utf8), extension: "txt")
        #expect(throws: TranscriptImport.Failure.self) {
            try parsed.entry(
                recording: URL(filePath: "/tmp/synthetic.wav"), duration: 3, source: "test.txt")
        }
    }

    @Test func transcriptSizeIsBoundedBeforeParsing() {
        #expect(throws: TranscriptImport.Failure.self) {
            try TranscriptImport.parse(
                Data(repeating: 65, count: TranscriptImport.maximumBytes + 1), extension: "txt")
        }
    }

    @MainActor
    @Test func importedTextIsEditableAndSurvivesReloadWithoutChangingTheSource() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appending(path: "Synthetic.srt")
        let contents = "1\n00:00:00,000 --> 00:00:01,000\nBonjour.\n"
        try Data(contents.utf8).write(to: transcript)
        let audio = URL(filePath: #filePath).deletingLastPathComponent().appending(
            path: "Fixtures/formats/clip.wav")
        let history = root.appending(path: "History")
        let model = AppModel(history: history)
        model.importTranscript(transcript, audio: audio)
        for _ in 0..<500 where model.stage.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.stage.isBusy)
        let entry = try #require(model.entries.first)
        #expect(entry.importSource == "Synthetic.srt")
        #expect(entry.timesSentences)
        model.edit(entry.id, paragraphAt: 0, text: "Correction.")
        model.savePending()
        let restored = try #require(AppModel(history: history).entry(entry.id))
        #expect(restored.paragraphs.first?.text == "Correction.")
        #expect(restored.original.first?.text == "Bonjour.")
        #expect(try String(contentsOf: transcript, encoding: .utf8) == contents)
        await model.shutDown()
    }

    @MainActor
    @Test func cancellingAnImportCreatesNoEntry() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(history: root)
        model.importTranscript(
            URL(filePath: "/tmp/missing.txt"), audio: URL(filePath: "/tmp/missing.wav"))
        model.cancel()
        for _ in 0..<500 where model.stage.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.stage.isBusy)
        #expect(model.entries.isEmpty)
        #expect(HistoryStore.all(in: root).entries.isEmpty)
        await model.shutDown()
    }
}
