// SPDX-License-Identifier: GPL-3.0-or-later
// Every test of one subject, kept together.
// swiftlint:disable file_length

import Foundation
import Testing

@testable import Polycop

@Test func updatingSeveralExportsReportsTheSuccessfulPrefixOnFailure() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let locked = folder.appending(path: "Locked")
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: folder)
    }
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    let text = folder.appending(path: "lecture.txt")
    let captions = locked.appending(path: "lecture.srt")
    try "old text".write(to: text, atomically: true, encoding: .utf8)
    try "old captions".write(to: captions, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
    do {
        _ = try Transcript.update(
            [text, captions],
            holding: [Transcript.digest("old text"), Transcript.digest("old captions")],
            with: [("txt", "new text"), ("srt", "new captions")])
        Issue.record("The unwritable second export should fail")
    } catch let partial as Transcript.PartialSave {
        #expect(partial.written == [text])
        #expect(try String(contentsOf: text, encoding: .utf8) == "new text")
        #expect(try String(contentsOf: captions, encoding: .utf8) == "old captions")
    }
}

private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> Segment {
    Segment(start: start, end: end, text: text)
}

// MARK: Transcript

private let paragraphFixtures = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/paragraphs")

/// Reads back the captions `Transcript.subRip` writes, one block per segment.
private func segments(fromSubRip text: String) throws -> [Segment] {
    try text.split(separator: "\n\n").map { block in
        let lines = block.split(separator: "\n")
        let times = try lines[1].split(separator: " --> ").map { clock -> Double in
            let parts = try clock.split(whereSeparator: { $0 == ":" || $0 == "," }).map {
                try #require(Double($0))
            }
            return parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / 1000
        }
        return Segment(start: times[0], end: times[1], text: lines[2...].joined(separator: " "))
    }
}

/// `lecture.txt` is the expected paragraph layout for `lecture.srt`, an
/// invented lecture whose pauses and sentence lengths reach both closing
/// rules: silences of 1.49 and 1.51 s, a paragraph past 120 words that closes
/// only at its next sentence end, and a paragraph crossing the ceiling above.
@Test func paragraphsMatchExpectedLayout() throws {
    let captions = try String(
        contentsOf: paragraphFixtures.appending(path: "lecture.srt"), encoding: .utf8)
    let expected = try String(
        contentsOf: paragraphFixtures.appending(path: "lecture.txt"), encoding: .utf8)
    let lecture = try segments(fromSubRip: captions)

    #expect(lecture.count == 30)
    #expect(Transcript.subRip(lecture) == captions)
    #expect(Transcript.text(lecture) == expected)
}

/// Times are compared in whole milliseconds, so an exact silence of 1.5 s
/// always closes the paragraph.
@Test func aSilenceOfOneAndAHalfSecondsClosesAParagraph() {
    let text = Transcript.text([
        segment(10.34, 11.84, "Premier."),
        segment(13.34, 14, "Second."),
        segment(15.49, 16, "Troisième."),
    ])

    #expect(text == "[00:00:10] Premier.\n\n[00:00:13] Second. Troisième.\n\n")
}

/// The window plays a paragraph from its first segment, to the millisecond.
@Test func aParagraphOpensAtItsFirstSegment() {
    let paragraphs = Transcript.paragraphs([
        segment(10.34, 11.84, "Premier."), segment(13.34, 14, "Second."),
    ])

    #expect(paragraphs.map(\.start) == [10340, 13340])
    #expect(paragraphs.map(\.seconds) == [10.34, 13.34])
    #expect(paragraphs.map(\.time) == ["00:00:10", "00:00:13"])
}

/// A segment with no words is not treated as speech, so it does not prevent
/// the surrounding silence from closing the paragraph.
@Test func aSegmentWithoutWordsDoesNotHideASilence() {
    let text = Transcript.text([
        segment(0, 1, "Bonjour."), segment(1, 5, "  "), segment(5.2, 6, "Oui."),
    ])

    #expect(text == "[00:00:00] Bonjour.\n\n[00:00:05] Oui.\n\n")
}

@Test func subRipUsesItsOwnTimeFormat() {
    let subtitles = Transcript.subRip([segment(1.5, 4.25, "Bonjour")])

    #expect(subtitles.contains("00:00:01,500 --> 00:00:04,250"))
    #expect(subtitles.hasPrefix("1\n"))
}

/// The engine reports hundredths of a second, and 12.34 held as a Double
/// falls just below it; an earlier version wrote 00:00:12,339.
@Test func subtitleTimesAreExactToTheMillisecond() {
    let subtitles = Transcript.subRip([segment(12.34, 3599.99, "Bonjour")])

    #expect(subtitles.contains("00:00:12,340 --> 00:59:59,990"))
}

/// Caption times come from the segments themselves, not from splitting text
/// by word count. An earlier version did the latter and placed four words in
/// a minute into four fifteen-second captions, against a seven-second limit.
@Test func captionsKeepTheTimesTheEngineReported() {
    let subtitles = Transcript.subRip([
        segment(0, 60, "un deux trois quatre"),
        segment(60, 63, "cinq"),
    ])

    #expect(subtitles.contains("00:00:00,000 --> 00:01:00,000"))
    #expect(subtitles.contains("00:01:00,000 --> 00:01:03,000"))
    #expect(subtitles.components(separatedBy: " --> ").count - 1 == 2)
}

/// Both formats must share one free name; naming them separately could write
/// "cours 2.txt" beside "cours.srt" when only one existed, and a player would
/// pair the wrong subtitle.
@Test func bothFormatsShareOneFreeName() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recording = folder.appending(path: "cours.m4a")

    let written = try Transcript.write(
        [("txt", "texte"), ("srt", "sous-titres")], as: folder.appending(path: "cours.txt"))

    // The subtitle takes the name chosen for the text, so a player pairs them.
    #expect(written.map(\.lastPathComponent) == ["cours.txt", "cours.srt"])
    _ = recording
}

/// A transcript stopped before the end must not pass for a whole lecture.
@Test func aPartialTranscriptSaysSoInItsName() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    #expect(Transcript.suggestedName(for: "cours.m4a", partial: true) == "cours (partial)")
    // A second transcript of the same lecture keeps its own name apart.
    #expect(Transcript.suggestedName(for: "cours 2.m4a", partial: false) == "cours 2")
}

/// A second save of the same result updates its files, but only while they
/// hold what was written; a file changed elsewhere is never replaced.
@Test func onlyUnchangedFilesAreUpdated() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let files = try Transcript.write(
        [("txt", "un"), ("srt", "1")], as: folder.appending(path: "cours.txt"))
    let first = ["un", "1"].map(Transcript.digest)

    let updated = try Transcript.update(
        files, holding: first, with: [("txt", "deux"), ("srt", "2")])
    #expect(updated == files)
    #expect(try String(contentsOf: files[0], encoding: .utf8) == "deux")

    try "changé à la main".write(to: files[0], atomically: true, encoding: .utf8)
    let second = ["deux", "2"].map(Transcript.digest)
    #expect(
        try Transcript.update(files, holding: second, with: [("txt", "trois"), ("srt", "3")]) == nil
    )
    #expect(try String(contentsOf: files[0], encoding: .utf8) == "changé à la main")

    // Subtitles are now off, so the files no longer match the formats.
    let changed = ["changé à la main", "2"].map(Transcript.digest)
    #expect(try Transcript.update(files, holding: changed, with: [("txt", "quatre")]) == nil)
}

/// The save panel is what asks before replacing a file, so a destination the
/// user chose is written exactly as named.
@Test func exportingWritesWhereTheUserChose() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let chosen = folder.appending(path: "Cours de psychologie.txt")

    let first = try Transcript.write([("txt", "un")], as: chosen)
    let second = try Transcript.write([("txt", "deux")], as: chosen)

    #expect(first == second)
    #expect(first.map(\.lastPathComponent) == ["Cours de psychologie.txt"])
    #expect(try String(contentsOf: chosen, encoding: .utf8) == "deux")
}

// MARK: Degeneration

/// A phrase that repeats enough times in a row, and takes over most of the
/// transcript, is reported with its own run and share.
@Test func aShortRepeatedPhraseIsReported() throws {
    let repeated =
        [segment(0, 2, "Bonjour à tous")]
        + (0..<50).map { segment(Double($0) * 2 + 2, Double($0) * 2 + 4, "Votre ville d'origine.") }

    let finding = try #require(Degeneration.check(repeated))

    #expect(finding.run == 50)
    #expect(finding.share > 0.9)
    #expect(Degeneration.warning(finding).contains("50"))
}

@Test func anOrdinaryTranscriptIsNotReported() {
    let ordinary = (0..<200).map {
        segment(Double($0) * 3, Double($0) * 3 + 3, "phrase numéro \($0) de ce cours")
    }

    #expect(Degeneration.check(ordinary) == nil)
}

/// Repeating a short answer a few times is speech, not a failure.
@Test func aFewRepeatsAreLeftAlone() {
    let normal =
        (0..<20).map { segment(Double($0) * 2, Double($0) * 2 + 2, "phrase \($0)") }
        + (0..<3).map { segment(Double($0) * 2 + 40, Double($0) * 2 + 42, "oui") }

    #expect(Degeneration.check(normal) == nil)
}

/// Qwen can repeat one word hundreds of times over a silent opening. The loop
/// is reduced as the official toolkit reduces it, the original is kept, and
/// the notice says where it was.
@Test func aLoopIsShortenedAndLocated() {
    let looped = segment(30, 60, Array(repeating: "Merci", count: 512).joined(separator: " "))
    let said = [segment(0, 30, "Bonjour à tous."), looped, segment(60, 90, "Commençons.")]

    let (speech, originals) = Degeneration.shortenLoops(said)

    #expect(speech.map(\.text) == ["Bonjour à tous.", "Merci Merci", "Commençons."])
    #expect(originals == [looped])
    #expect(Degeneration.loopNotice(originals)?.contains("00:00:30") == true)
    #expect(Degeneration.loopNotice([]) == nil)
    #expect(Degeneration.shortened(String(repeating: "a", count: 40)) == "a")
    #expect(Degeneration.shortened(String(repeating: "ha", count: 30) + " fin") == "ha fin")
}

/// Speech, emphasis, and short repeated answers are left unchanged; the rule
/// requires more than twenty repeats in a row.
@Test func speechIsNotShortened() {
    let window = """
        Aujourd'hui nous reprenons la question de la mémoire là où nous l'avions laissée la \
        semaine dernière. Vous vous souvenez que nous avions distingué trois temps : \
        l'encodage, le stockage et la récupération. Ce matin je voudrais montrer que cette \
        distinction, commode pour présenter les expériences, ne dit presque rien de ce qui se \
        passe dans le cerveau. Prenons un exemple simple, celui d'un numéro de téléphone que \
        l'on retient le temps de le composer, puis que l'on oublie aussitôt. Qu'est-ce qui a \
        été encodé, et pour combien de temps ?
        """

    #expect(Degeneration.shortened(window) == window)
    #expect(Degeneration.shortened("Non, non, non, non.") == "Non, non, non, non.")
    let twenty = Array(repeating: "très", count: 20).joined(separator: " ")
    #expect(Degeneration.shortened(twenty) == twenty)
}

/// A model that tells speakers apart opens a paragraph at each new speaker,
/// and says who speaks; one that does not is laid out as before.
@Test func aNewSpeakerOpensAParagraph() {
    let turns = [
        Segment(start: 0, end: 2, text: "Bonjour à tous.", speaker: "S01"),
        Segment(start: 2.2, end: 4, text: "Commençons.", speaker: "S01"),
        Segment(start: 4.1, end: 5, text: "Une question ?", speaker: "S02"),
    ]

    #expect(
        Transcript.paragraphs(turns).map(\.text) == [
            "Speaker 1: Bonjour à tous. Commençons.", "Speaker 2: Une question ?",
        ])
    #expect(Transcript.paragraphs(turns.map { $0.replacing(text: $0.text) }).count == 2)
    #expect(Transcript.label(of: nil) == nil && Transcript.label(of: "SPEAKER") == nil)
}

// MARK: Credits

/// The first two were observed at the start of real recordings; the rest come
/// from published hallucination reports. The video sign-off is the credit the
/// engine writes most often, usually as one long repeated loop.
@Test(arguments: [
    "Sous-titrage Société Radio-Canada",
    " Radio-Canada.",
    "Sous-titres réalisés par la communauté d\u{2019}Amara.org",
    "Sous-titres réalisés para la communauté d\u{2019}Amara.org",
    "SOUS-TITRAGE ST' 501",
    "Merci d\u{2019}avoir regardé cette vidéo.",
    "N'oubliez pas de vous abonner !",
])
func aCreditLineIsRemoved(_ line: String) {
    let (speech, credits) = Credits.separate([
        segment(0, 30, line), segment(30, 33, "Bonjour à tous."),
    ])

    #expect(speech.map(\.text) == ["Bonjour à tous."])
    #expect(credits.count == 1)
}

/// Matching the word "sous-titres" directly would remove real speech about
/// subtitles. Thanks that end a lecture are also on the published
/// hallucination list, but are kept, since only lines addressed to a video
/// audience are removed.
@Test func speechAboutSubtitlesIsKept() {
    let said = [
        segment(0, 2, "On met les sous-titres pour la vidéo ?"),
        segment(2, 6, "Le sous-titrage de Radio-Canada était en retard."),
        segment(6, 8, "Merci."),
        segment(8, 12, "Merci pour votre attention."),
        segment(12, 14, "Merci à tous."),
        segment(14, 16, "Au revoir."),
    ]

    #expect(Credits.separate(said).speech == said)
    #expect(Credits.notice([]) == nil)
}

@Test func theNoticeCountsAndQuotesTheCredits() {
    let credits = (0..<13).map { segment(Double($0) * 30, Double($0) * 30 + 30, "Radio-Canada") }
    let notice = Credits.notice(credits) ?? ""

    #expect(notice.contains("13"))
    #expect(notice.contains("“Radio-Canada”"))
}

// MARK: Cleaning

@Test func sweepRemovesLeftoversAndKeepsAnUnfinishedTransfer() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let offered = ModelCatalog.recommended.id
    let finished = folder.appending(path: offered)
    let ofFinished = folder.appending(path: offered + ".resume")
    let ofUnknown = folder.appending(path: "ggml-retired-model.bin.resume")
    let ofUnfinished = folder.appending(path: ModelCatalog.largeV3.id + ".resume")

    for file in [finished, ofFinished, ofUnknown, ofUnfinished] {
        try Data("x".utf8).write(to: file)
    }
    ModelStore.sweep(in: folder)

    let manager = FileManager.default
    // The model finished downloading, so its resume data is stale.
    #expect(!manager.fileExists(atPath: ofFinished.path(percentEncoded: false)))
    // The catalogue no longer offers this one.
    #expect(!manager.fileExists(atPath: ofUnknown.path(percentEncoded: false)))
    // This transfer can still be continued, so it stays.
    #expect(manager.fileExists(atPath: ofUnfinished.path(percentEncoded: false)))
    #expect(manager.fileExists(atPath: finished.path(percentEncoded: false)))
}

/// A result of one to three distinct segments has no repetition at all.
@Test(arguments: [1, 2, 3])
func aShortCorrectResultIsNotReported(_ count: Int) {
    let short = (0..<count).map { segment(Double($0), Double($0) + 1, "Phrase \($0)") }
    #expect(Degeneration.check(short) == nil)
}

/// The run and the share reported belong to the same phrase.
@Test func theFindingDescribesOnePhrase() {
    let run = (0..<12).map { segment(Double($0), Double($0) + 1, "Merci.") }
    let alternating = (0..<40).map {
        segment(Double($0) + 12, Double($0) + 13, $0.isMultiple(of: 2) ? "oui" : "non")
    }
    let finding = Degeneration.check(run + alternating)

    #expect(finding?.phrase == "Merci.")
    #expect(finding?.run == 12)
    #expect(finding?.share == 12.0 / 52.0)
}

/// When a later file cannot be written, the earlier one stays and is named.
@Test func aPartialSaveNamesWhatWasWritten() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recording = folder.appending(path: "cours.m4a")

    // The second name points into a folder that does not exist.
    do {
        _ = try Transcript.write(
            [("txt", "texte"), ("srt/missing", "x")],
            as: recording.deletingPathExtension()
                .appendingPathExtension("txt"))
        Issue.record("the save should have failed")
    } catch let partial as Transcript.PartialSave {
        #expect(partial.written.map(\.lastPathComponent) == ["cours.txt"])
        #expect(partial.localizedDescription.contains("cours.txt"))
    }
}

@Test func marksTheWordsThatWereNotWrittenByTheEngine() {
    let original = "Le principe de plaisir selon Freud."
    let corrected = "Le principe de réalité selon Freud."

    let changed = Edits.changed(from: original, to: corrected)
    let ranges = Edits.ranges(of: changed, in: corrected)

    #expect(changed == [3])
    #expect(ranges.map { String(corrected[$0]) } == ["réalité"])
    // Nothing changed, nothing marked; everything new, everything marked.
    #expect(Edits.changed(from: original, to: original).isEmpty)
    #expect(Edits.changed(from: "", to: "Deux mots").count == 2)
}

/// Without the ceiling, a lecturer who never pauses or finishes a sentence
/// would produce one very long paragraph with a single seek point.
@Test func closesAParagraphThatRunsTooLong() {
    let spoken = (0..<40).map {
        segment(Double($0) * 10, Double($0) * 10 + 10, "et puis encore une idée qui continue")
    }

    let paragraphs = Transcript.paragraphs(spoken)

    #expect(paragraphs.count == 5)
    let lengths = zip(paragraphs, paragraphs.dropFirst()).map { $1.seconds - $0.seconds }
    #expect(lengths.allSatisfy { $0 <= Transcript.longest + 10 })
}

@Test func aLargePasteKeepsDiffWorkBounded() {
    let original = "First " + String(repeating: "old ", count: 4000) + "last"
    let edited = "First " + String(repeating: "new ", count: 4000) + "last"
    #expect(Edits.changed(from: original, to: edited) == Set(1...4000))
    #expect(Edits.changed(from: original, to: original).isEmpty)
}

@Test func aTextExportDoesNotOverwriteAnUnconfirmedSubtitle() throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let subtitle = folder.appending(path: "lecture.srt")
    let text = folder.appending(path: "lecture.txt")
    try "Existing subtitles".write(to: subtitle, atomically: true, encoding: .utf8)
    #expect(throws: Transcript.ExistingSubtitle.self) {
        try Transcript.write([("txt", "New text"), ("srt", "New subtitles")], as: text)
    }
    #expect(try String(contentsOf: subtitle, encoding: .utf8) == "Existing subtitles")
    #expect(!FileManager.default.fileExists(atPath: text.path))
}

@Test func manySeparateLoopsAreCollapsedWithoutRecursiveCopies() {
    let block = String(repeating: "abc ", count: 25) + "end "
    let source = (0..<2000).map { "\($0) " + block }.joined()
    let expected = (0..<2000).map { "\($0) abc end " }.joined()
    #expect(Degeneration.shortened(source) == expected)
}

@Test(arguments: [
    ("Euh, donc on commence.", "Donc on commence."),
    ("Donc, euh, on commence.", "Donc, on commence."),
    ("On commence euh.", "On commence."),
    ("On commence, euh.", "On commence."),
    ("Oui, hum ?", "Oui ?"),
    ("Euh... bonjour.", "Bonjour."),
    ("C'est bien. Hum… alors on voit.", "C'est bien. Alors on voit."),
    ("Um, so we start.", "So we start."),
    ("Le côté humain de l'heure.", "Le côté humain de l'heure."),
    ("Ben voilà, du coup on arrête.", "Ben voilà, du coup on arrête."),
])
func hesitationsLeaveTheTextAndItsMeaning(text: String, expected: String) {
    #expect(Hesitations.removed(from: text) == expected)
}

@Test func theTextExportFollowsTheChosenLayout() {
    let paragraphs = [
        Transcript.Paragraph(start: 0, text: "Bonjour à tous."),
        Transcript.Paragraph(start: 65_000, text: "On commence."),
    ]
    #expect(
        Transcript.text(paragraphs, layout: .timestamped, title: "Cours")
            == "[00:00:00] Bonjour à tous.\n\n[00:01:05] On commence.\n\n")
    #expect(
        Transcript.text(paragraphs, layout: .plain, title: "Cours")
            == "Bonjour à tous.\n\nOn commence.\n\n")
    #expect(
        Transcript.text(paragraphs, layout: .markdown, title: "Cours")
            == "# Cours\n\n**00:00:00** Bonjour à tous.\n\n**00:01:05** On commence.\n\n")
    #expect(Transcript.TextLayout.markdown.suffix == "md")
    #expect(Transcript.TextLayout.plain.suffix == "txt")
}
