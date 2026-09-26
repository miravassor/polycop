// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A recording added to the app, its settings, and, once transcribed, its
/// text, edits, and export state.
///
/// Every change is written to disk immediately, so nothing is lost if the app
/// quits before a save. The audio file itself is not copied; playback reads
/// it from its original location.
nonisolated struct Entry: Identifiable, Equatable, Codable, Sendable {
    enum State: Equatable, Codable, Sendable {
        case waiting
        case running
        case finished
        /// Cancelled by the user, or interrupted by quitting; partial results
        /// are kept.
        case stopped
        case failed(String)
    }

    var id: UUID
    /// Where the recording was when it was added, or wherever the user has
    /// relinked it to since.
    private(set) var recording: URL
    /// A name of its own, which a second transcript of the same recording needs.
    var title: String?
    /// Finds the recording again after it moves on the same disk.
    private(set) var bookmark: Data?
    var added: Date
    /// Settings this recording transcribes with. They track the values shown
    /// on the page until the run starts, then stay fixed for that run (see
    /// `adopt`).
    private(set) var modelFile: String
    private(set) var glossary: String?
    private(set) var prompt: String?
    /// The language it was transcribed in. Absent in entries created before
    /// the app offered a language choice; those recordings are all French.
    private(set) var language: String?
    private(set) var skipsSilence: Bool
    var subtitles: Bool
    var state: State

    /// Everything the engine wrote, credit lines included.
    var decoded: [Segment] = []
    /// What the user reads, edits and saves.
    var paragraphs: [Transcript.Paragraph] = []
    var originalParagraphs: [Transcript.Paragraph]?
    /// Audio positions marked for review; optional for older history records.
    var reviewMarks: Set<Int>?
    var showsCredits = false
    var isPartial = false
    var isEdited = false
    var glossaryWarning: String?
    /// Seconds of audio in the recording, once decoded.
    var duration: TimeInterval?
    /// How long transcribing it took, converting and loading the model
    /// included, and summed over a job that was paused and resumed.
    var transcribedIn: TimeInterval?
    /// The stretches the detector kept, in seconds, when silences are skipped.
    var speech: [ClosedRange<TimeInterval>]?
    /// Where transcription resumed after a pause, in seconds. Words near such
    /// a point can be missing or repeated.
    var resumedAt: [TimeInterval]?
    /// Whether segments align to sentence boundaries, set by the run that
    /// wrote them. True for Qwen once the aligner has timed its words; nil
    /// lets the model decide.
    var sentenceTimes: Bool?
    var importSource: String?
    var saved: [URL] = []
    /// Digests of what each saved file held, to tell whether it is still ours.
    var savedDigests: [String] = []
    var isSaved = false
    var folderID: UUID?

    init(
        recording: URL, modelFile: String, glossary: Glossary?, skipsSilence: Bool,
        subtitles: Bool, language: String = "fr", added: Date = .now
    ) {
        id = UUID()
        self.recording = recording
        bookmark = try? recording.bookmarkData()
        self.added = added
        self.modelFile = modelFile
        self.glossary = glossary?.name
        prompt = glossary?.prompt(in: language)
        self.language = language
        self.skipsSilence = skipsSilence
        self.subtitles = subtitles
        state = .waiting
    }

    var name: String { title ?? recording.lastPathComponent }

    /// Takes the settings shown now, for a recording that has not started yet.
    mutating func adopt(
        modelFile: String, glossary: Glossary?, language: String, skipsSilence: Bool
    ) {
        guard state == .waiting else { return }
        self.modelFile = modelFile
        self.glossary = glossary?.name
        prompt = glossary?.prompt(in: language)
        self.language = language
        self.skipsSilence = skipsSilence
    }

    /// A second, independent transcript of the same recording. Copies the
    /// current, possibly edited text rather than the engine's original
    /// output, since duplicating is normally done to branch off an edit in
    /// progress.
    func duplicated(among names: Set<String>) -> Entry {
        var copy = self
        copy.id = UUID()
        copy.added = .now
        copy.title = Entry.freeName(from: name, among: names)
        copy.saved = []
        copy.savedDigests = []
        copy.isSaved = false
        return copy
    }

    /// Queues the same recording again with the same settings (model,
    /// glossary, language, silence policy, and folder). Discards everything
    /// the previous attempt produced, since this starts a fresh run rather
    /// than copying its result.
    func retrying() -> Entry {
        var again = self
        again.id = UUID()
        again.added = .now
        again.title = nil
        again.state = .waiting
        again.clearResult()
        return again
    }

    /// Resets everything a transcription run produces, back to a fresh entry's
    /// defaults.
    private mutating func clearResult() {
        decoded = []
        paragraphs = []
        originalParagraphs = nil
        reviewMarks = nil
        showsCredits = false
        isPartial = false
        isEdited = false
        glossaryWarning = nil
        duration = nil
        transcribedIn = nil
        speech = nil
        resumedAt = nil
        sentenceTimes = nil
        importSource = nil
        saved = []
        savedDigests = []
        isSaved = false
    }

    /// "Cours.wav" becomes "Cours 2.wav", then "Cours 3.wav". The number is
    /// inserted before the extension, not appended after it.
    static func freeName(from name: String, among names: Set<String>) -> String {
        let file = name as NSString
        let suffix = file.pathExtension
        var stem = file.deletingPathExtension
        if let range = stem.range(of: #" \d+$"#, options: .regularExpression) {
            stem.removeSubrange(range)
        }
        var number = 2
        while true {
            let candidate = suffix.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(suffix)"
            if !names.contains(candidate) { return candidate }
            number += 1
        }
    }

    /// Whether the recording is still where the bookmark or the path says.
    /// Listening, transcribing again and repairing all need it.
    var hasRecording: Bool {
        FileManager.default.fileExists(atPath: location.path(percentEncoded: false))
    }

    /// Where the recording is now, or where it was if the bookmark fails.
    var location: URL { resolved().url }

    /// The recording, and whether its bookmark should be renewed. macOS can
    /// mark a bookmark stale while still resolving it, so renewal happens at
    /// the start of an operation instead of here, keeping this property free
    /// of side effects.
    func resolved() -> (url: URL, stale: Bool) {
        var stale = false
        guard let bookmark,
            let found = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        else { return (recording, false) }
        return (found, stale)
    }

    /// Points at the recording again, after it moved or was renamed outside
    /// the app. The transcript and everything exported from it are untouched.
    mutating func relink(to file: URL) {
        recording = file
        bookmark = try? file.bookmarkData()
    }

    /// The unedited text, laid out using the paragraph boundaries already in
    /// `paragraphs`, so recomputing it does not also change where paragraphs
    /// break.
    var original: [Transcript.Paragraph] {
        if let originalParagraphs { return originalParagraphs }
        guard !paragraphs.isEmpty else { return Transcript.paragraphs(shown) }
        var result = paragraphs.map { Transcript.Paragraph(start: $0.start, text: "") }
        var index = 0
        for segment in shown {
            while index + 1 < result.count,
                result[index + 1].start <= Int((segment.start * 1000).rounded())
            {
                index += 1
            }
            let words = segment.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !words.isEmpty {
                if !result[index].text.isEmpty { result[index].text += " " }
                result[index].text += words
            }
        }
        return result
    }

    /// Whether segments are sentence length, which subtitles require.
    var timesSentences: Bool {
        sentenceTimes ?? ModelCatalog.model(modelFile)?.engine.timesSentences ?? true
    }

    /// The segments as shown and saved. Credit lines stay hidden and loops
    /// stay shortened until put back.
    var shown: [Segment] { showsCredits ? decoded : cleaned.speech }
    var hiddenCredits: [Segment] { showsCredits ? [] : cleaned.credits }
    var shortenedLoops: [Segment] { showsCredits ? [] : cleaned.looped }

    /// Segments with credit lines removed and loops shortened, until put back.
    private var cleaned: (speech: [Segment], credits: [Segment], looped: [Segment]) {
        let (heard, credits) = Credits.separate(decoded)
        let (speech, looped) = Degeneration.shortenLoops(heard)
        return (speech, credits, looped)
    }
    var repetitionWarning: String? { Degeneration.check(shown).map(Degeneration.warning) }

    /// Stretches where one phrase repeats in a row, which can be transcribed
    /// again. Read from the raw segments, which is what a repair replaces.
    var repeats: [ClosedRange<Int>] { Degeneration.repeats(in: decoded) }

    /// The paragraphs holding a point where transcription resumed.
    var resumedParagraphs: Set<Int> {
        Set((resumedAt ?? []).map { time in paragraphs.lastIndex { $0.seconds <= time } ?? 0 })
    }

    /// Recording time outside the stretches the detector kept: total duration
    /// minus kept time, overlaps counted once and clipped to the recording
    /// length. Not exactly speech lost, since the kept stretches include some
    /// silence too.
    var leftOut: TimeInterval? {
        guard let speech, let duration else { return nil }
        var kept = 0.0
        var reached = 0.0
        for stretch in speech.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = max(stretch.lowerBound, reached)
            let end = min(stretch.upperBound, duration)
            if end > start {
                kept += end - start
                reached = end
            }
        }
        return max(0, duration - kept)
    }

    /// Takes what the engine wrote, finished or stopped by a pause, and lays it
    /// out afresh. Corrections belong to an earlier layout, so none are kept.
    mutating func publish(_ result: [Segment], partial: Bool) {
        decoded = result
        isPartial = partial
        paragraphs = Transcript.paragraphs(shown)
        originalParagraphs = paragraphs
        isEdited = false
        isSaved = false
    }

    var reviewParagraphs: Set<Int> {
        Set(
            (reviewMarks ?? []).compactMap { time in
                paragraphs.lastIndex { $0.start <= time }
            })
    }

    mutating func toggleReview(paragraphAt index: Int) {
        guard paragraphs.indices.contains(index) else { return }
        let marks = reviewMarks ?? []
        let existing = marks.filter { time in
            paragraphs.lastIndex { $0.start <= time } == index
        }
        reviewMarks =
            existing.isEmpty
            ? marks.union([paragraphs[index].start]) : marks.subtracting(existing)
    }

    mutating func edit(paragraphAt index: Int, text: String) {
        guard paragraphs.indices.contains(index), paragraphs[index].text != text else { return }
        if originalParagraphs == nil { originalParagraphs = original }
        paragraphs[index].text = text
        isEdited = paragraphs != original
        isSaved = false
    }

    /// Replaces each match with `replacement`. Ranges are replaced from the end
    /// of each paragraph so the earlier ones stay valid.
    mutating func replace(_ matches: [TranscriptSearch.Match], with replacement: String) {
        var replaced = paragraphs
        for (index, inParagraph) in Dictionary(grouping: matches, by: \.paragraph)
        where replaced.indices.contains(index) {
            let text = NSMutableString(string: replaced[index].text)
            for match in inParagraph.sorted(by: { $0.range.location > $1.range.location })
            where NSMaxRange(match.range) <= text.length {
                text.replaceCharacters(in: match.range, with: replacement)
            }
            replaced[index].text = text as String
        }
        guard replaced != paragraphs else { return }
        if originalParagraphs == nil { originalParagraphs = original }
        paragraphs = replaced
        isEdited = paragraphs != original
        isSaved = false
    }

    /// The text alone cannot prove a hidden line was not said, so the user
    /// decides whether to show it. Refused once the text is edited, since the
    /// paragraph layout has since changed.
    ///
    /// Returns whether credits were put back, so a caller can tell a refusal
    /// from a transcript that already showed them.
    @discardableResult
    mutating func putBackCredits() -> Bool {
        guard !isEdited, !showsCredits else { return false }
        showsCredits = true
        paragraphs = Transcript.paragraphs(shown)
        originalParagraphs = paragraphs
        isSaved = false
        return true
    }
}
