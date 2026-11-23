// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

@Test func srtHandlesFractionalSeparatorsSpacesMultilineAndCRLF() throws {
    let text =
        "1\r\n  00:00:01,500 --> 00:00:02.25  \r\n<i>Bonjour</i>\r\n<b>suite</b>\r\n \t \r\n  \r\n"
        + "00:00:03,5 --> 00:00:04.750\r\nDeuxième bloc.\r\n"
    let parsed = try TranscriptImport.parse(Data(text.utf8), extension: "srt")
    #expect(parsed.cues.count == 2)
    #expect(parsed.cues[0].start == 1.5)
    #expect(parsed.cues[0].end == 2.25)
    #expect(parsed.cues[0].text == "<i>Bonjour</i>\n<b>suite</b>")
    #expect(parsed.cues[1].start == 3.5)
    #expect(parsed.cues[1].end == 4.75)
    #expect(parsed.cues[1].text == "Deuxième bloc.")

    let loneCR = "1\r00:00:00,500 --> 00:00:01,000\rLigne un\rLigne deux\r\r"
    let crParsed = try TranscriptImport.parse(Data(loneCR.utf8), extension: "SRT")
    #expect(crParsed.cues.map(\.text) == ["Ligne un\nLigne deux"])
}

@Test func webVTTHandlesHeadersCueSettingsTagsAndOptionalHours() throws {
    let text = """
        WEBVTT - Cours de synthèse
        Kind: captions
        Language: fr

        NOTE
        Commentaire sur plusieurs lignes.

        STYLE
        ::cue { color: white; }

        REGION
        id:bas

        cue-1
        00:01.50 --> 00:02.750 align:start position:10% line:0
        <v Prof>Bonjour</v>
        <c.em>à tous.</c>
        \t
        01:02:03.400 --> 01:02:05.5 line:90%
        Suite du cours.
        """
    let parsed = try TranscriptImport.parse(Data(text.utf8), extension: "vtt")
    #expect(parsed.cues.count == 2)
    #expect(parsed.cues[0].start == 1.5)
    #expect(parsed.cues[0].end == 2.75)
    #expect(parsed.cues[0].text == "<v Prof>Bonjour</v>\n<c.em>à tous.</c>")
    #expect(parsed.cues[1].start == 3723.4)
    #expect(parsed.cues[1].end == 3725.5)
    #expect(parsed.cues[1].text == "Suite du cours.")
}

@Test(arguments: [
    "WEBVTT\n00:00.000 --> 00:01.000\nSans ligne vide.",
    "WEBVTT\n\nNOTE 00:00.000 --> 00:01.000\n\n00:01.000 --> 00:02.000\nSuite.",
])
func webVTTRejectsHeaderBlockContainingArrow(_ text: String) {
    #expect(throws: TranscriptImport.Failure.invalidTimes) {
        try TranscriptImport.parse(Data(text.utf8), extension: "vtt")
    }
}

@Test func plainTextHandlesBracketedBareMultilineAndCRLF() throws {
    let bracketed =
        "En-tête ignoré\r\n"
        + "[00:01] Premier paragraphe.\r\nLigne suivante.\r\n"
        + "[00:00:05,500 --> 00:00:07.25] Deuxième.\r\n"
        + "[1:02:03] Troisième.\r\n"
    let parsedBracketed = try TranscriptImport.parse(Data(bracketed.utf8), extension: "txt")
    #expect(parsedBracketed.cues.map(\.start) == [1, 5.5, 3723])
    #expect(parsedBracketed.cues.map(\.end) == [nil, 7.25, nil])
    #expect(
        parsedBracketed.cues.map(\.text) == [
            "Premier paragraphe.\nLigne suivante.", "Deuxième.", "Troisième.",
        ])

    let bare =
        "Titre\r\n2026-01-05\r\n"
        + "00:01 Bonjour.\r\n[note entre crochets]\r\n"
        + "00:02,50\r\nLigne dessous.\r\n"
        + "1:02:03.250   Fin.\r\n"
    let parsedBare = try TranscriptImport.parse(Data(bare.utf8), extension: "txt")
    #expect(parsedBare.cues.map(\.start) == [1, 2.5, 3723.25])
    #expect(parsedBare.cues.allSatisfy { $0.end == nil })
    #expect(
        parsedBare.cues.map(\.text) == [
            "Bonjour.\n[note entre crochets]", "Ligne dessous.", "Fin.",
        ])
}

@Test func bareTimestampMatchingDoesNotBacktrackOnSpacesBeforeLineSeparator() throws {
    let line = "00:01" + String(repeating: " ", count: 5_000) + "a\u{2028}b"
    let text = "00:00 Début.\n" + line
    let parsed = try TranscriptImport.parse(Data(text.utf8), extension: "txt")
    #expect(parsed.cues.count == 1)
    #expect(parsed.cues[0].start == 0)
    #expect(parsed.cues[0].text == "Début.\n" + line)
}

@Test func mossParsesMultilineSpeakersAndRejectsUntimedGaps() throws {
    let text =
        "[0]\r\n  [S01]Première ligne\r\navec [crochet] dedans.[1.5]\r\n \t\r\n"
        + "[1.5] [S02]Deuxième tour.[3.25]\r\n"
    let parsed = try TranscriptImport.parse(Data(text.utf8), extension: "txt")
    #expect(parsed.cues.count == 2)
    #expect(parsed.cues[0].start == 0)
    #expect(parsed.cues[0].end == 1.5)
    #expect(parsed.cues[0].speaker == "S01")
    #expect(parsed.cues[0].text == "Première ligne\navec [crochet] dedans.")
    #expect(parsed.cues[1].start == 1.5)
    #expect(parsed.cues[1].end == 3.25)
    #expect(parsed.cues[1].speaker == "S02")
    #expect(parsed.cues[1].text == "Deuxième tour.")

    let malformed = [
        "[0][S01]Bonjour.[1] texte perdu [1][S02]Suite.[2]",
        "[0][S01]Passage sans fin.",
        "[0][S01]   \n  [1]",
        "[2][S01]Inversé.[1]",
    ]
    for bad in malformed {
        #expect(throws: TranscriptImport.Failure.invalidTimes) {
            try TranscriptImport.parse(Data(bad.utf8), extension: "txt")
        }
    }
}

@Test func fourHourBoundaryTimestampIsAccepted() throws {
    let srt = "1\n03:59:59,000 --> 04:00:00,000\nFin.\n"
    let parsedSRT = try TranscriptImport.parse(Data(srt.utf8), extension: "srt")
    #expect(parsedSRT.cues.first?.end == AudioDecoder.longestRecording)

    let bare = "04:00:00 Fin."
    let parsedBare = try TranscriptImport.parse(Data(bare.utf8), extension: "txt")
    #expect(parsedBare.cues.first?.start == AudioDecoder.longestRecording)

    let moss = "[14399][S01]Fin.[14400]"
    let parsedMoss = try TranscriptImport.parse(Data(moss.utf8), extension: "txt")
    #expect(parsedMoss.cues.first?.end == AudioDecoder.longestRecording)
}

@Test(arguments: [
    ("srt", "1\n04:00:00,000 --> 04:00:00,001\nAu-delà.\n"),
    ("srt", "1\n04:00:01,000 --> 04:00:02,000\nAu-delà.\n"),
    ("srt", "1\n05:00:00,000 --> 05:00:01,000\nAu-delà.\n"),
    ("srt", "1\n00:60:00,000 --> 00:60:01,000\nMinutes.\n"),
    ("srt", "1\n00:00:60,000 --> 00:01:01,000\nSecondes.\n"),
    ("srt", "1\n00:00:02,000 --> 00:00:03,000\nDeux.\n\n2\n00:00:01,000 --> 00:00:02,000\nUn.\n"),
    ("srt", "1\n00:00:01,000 --> 00:00:02,000\n"),
    ("srt", "ligne 0\nligne 1\n00:00:01,000 --> 00:00:02,000\nTrop bas.\n"),
    ("vtt", "WEBVTT\n\n00:02.000 --> 00:01.000\nInversé."),
    ("txt", "[04:00:01] Au-delà."),
    ("txt", "[-01:00:00] Négatif."),
    ("txt", "[00:00:-1] Négatif."),
    ("txt", "00:05 Deux.\n00:04 Un."),
    ("txt", "[14399][S01]Au-delà.[14400.1]"),
    ("txt", "[2][S01]Deux.[3]\n[1][S02]Un.[2]"),
])
func invalidOutOfOrderAndOverFourHourTimestampsAreRefused(suffix: String, text: String) {
    #expect(throws: TranscriptImport.Failure.invalidTimes) {
        try TranscriptImport.parse(Data(text.utf8), extension: suffix)
    }
}

@Test func jsonVariantsCoverAllTimingAndRowConventions() throws {
    let clockJSON =
        #"{"transcription":[{"timestamps":{"from":"00:00:01,500","to":"00:00:02,250"},"text":"Bonjour."}]}"#
    let clockParsed = try TranscriptImport.parse(Data(clockJSON.utf8), extension: "json")
    #expect(clockParsed.cues.first?.start == 1.5)
    #expect(clockParsed.cues.first?.end == 2.25)

    let segmentJSON =
        #"{"segments":[{"start_time":2.0,"end_time":3.5,"speaker":"S02","text":"Suite."}]}"#
    let segmentParsed = try TranscriptImport.parse(Data(segmentJSON.utf8), extension: "json")
    #expect(segmentParsed.cues.first?.start == 2)
    #expect(segmentParsed.cues.first?.end == 3.5)
    #expect(segmentParsed.cues.first?.speaker == "S02")

    let timeStampsJSON =
        #"{"time_stamps":[{"text":"Bonjour","start":0,"end":0.5},{"text":"tous.","start":0.5,"end":1.0}]}"#
    let timeStampsParsed = try TranscriptImport.parse(Data(timeStampsJSON.utf8), extension: "json")
    #expect(timeStampsParsed.isWordLevel)
    #expect(timeStampsParsed.cues.count == 2)

    let wordsNoText =
        #"{"words":[{"word":"Bonjour","start":0,"end":0.5},{"word":"monde.","start":0.5,"end":1.0}]}"#
    let wordsParsed = try TranscriptImport.parse(Data(wordsNoText.utf8), extension: "json")
    #expect(wordsParsed.isWordLevel)
    let entry = try wordsParsed.entry(
        recording: URL(filePath: "/tmp/synthetic.wav"), duration: 2, source: "Words.json")
    #expect(!entry.paragraphs.isEmpty)

    for badRate in [
        #"{"sample_rate":999,"segments":[{"start_sample":0,"end_sample":100,"text":"A"}]}"#,
        #"{"sample_rate":384001,"segments":[{"start_sample":0,"end_sample":100,"text":"A"}]}"#,
        #"{"sample_rate":true,"segments":[{"start_sample":0,"end_sample":100,"text":"A"}]}"#,
    ] {
        #expect(throws: TranscriptImport.Failure.invalidTimes) {
            try TranscriptImport.parse(Data(badRate.utf8), extension: "json")
        }
    }

    #expect(throws: TranscriptImport.Failure.unsupported) {
        try TranscriptImport.parse(Data(#"{"other":[]}"#.utf8), extension: "json")
    }
}

@Test func importedEntryUsesNamedModelConstantAndDropsAlignmentPromise() throws {
    #expect(TranscriptImport.importedModel == "imported")

    let parsed = try TranscriptImport.parse(
        Data("[0.5][S01]Bonjour.[1.5]".utf8), extension: "txt")
    let entry = try parsed.entry(
        recording: URL(filePath: "/tmp/synthetic.wav"), duration: 5, source: "Cours.txt")
    #expect(entry.modelFile == TranscriptImport.importedModel)
    #expect(entry.importSource == "Cours.txt")
    #expect(entry.title == "Cours")
    #expect(entry.state == .finished)
    let label = try #require(Transcript.label(of: "S01"))
    #expect(entry.paragraphs.first?.text == "\(label) Bonjour.")

    let unsupported = try #require(TranscriptImport.Failure.unsupported.errorDescription)
    #expect(!unsupported.lowercased().contains("yet"))
    #expect(!unsupported.lowercased().contains("aligned"))
}
