// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One transcript: reads its record below `ContentView`, so edits do not
/// redraw the window's split view, and hands `LoadedEntryView` the record.
struct EntryView: View {
    let model: AppModel
    let id: Entry.ID

    /// Resizable as the library is: from the narrowest that keeps every label
    /// whole to room for a larger picture.
    static let inspectorWidths: ClosedRange<CGFloat> = 360...520
    static let idealInspectorWidth: CGFloat = 380

    /// About 75 characters a line, times included, at a text size.
    static func readingWidth(textSize: Double) -> CGFloat { 40 * textSize + 160 }

    var body: some View {
        if let entry = model.entry(id) {
            LoadedEntryView(model: model, entry: entry)
        } else {
            NewTranscriptionView(model: model)
        }
    }
}

/// Keeps what is derived from a transcript's segments and hands `EntryPage`
/// facts a correction typed in the text leaves equal, so the page's title,
/// toolbar, inspector and focused values skip their body.
private struct LoadedEntryView: View {
    let model: AppModel
    let entry: Entry
    /// Derived segment data kept off `EntryPage.Facts`, so typing neither
    /// recomputes it nor compares word arrays on the page's structure.
    @State private var segments = PageSegments()

    var body: some View {
        // In the body, not in `onChange`, which runs after it and would pair
        // this record with what an earlier one yielded: `segments` is no
        // observed state, so writing it tells no view, and it works out again
        // only what its inputs changed. `EntryText` reads it later in the same
        // update.
        segments.update(for: entry, model: model)
        let inspectorFacts = EntryInspector.Facts(
            entry: entry, findings: segments.findings, textGaps: segments.textGaps,
            canRebuild: segments.canRebuild, lastExport: segments.lastExport, model: model)
        let pageFacts = EntryPage.Facts(
            entry: entry, hasRecording: segments.hasRecording,
            hasTimedWords: segments.hasTimedWords, inspector: inspectorFacts, model: model)
        return EntryPage(model: model, facts: pageFacts, segments: segments)
    }
}

/// What a transcript's segments yield for the page: grouped timed words,
/// notices' findings, text gaps, whether any word is timed, and whether a
/// warning's rebuild can run; with whether its recording and its last export
/// are on disk. Updated synchronously by `LoadedEntryView` as its inputs
/// change and read by `LoadedEntryView` and `EntryText`, never by `EntryPage`.
final class PageSegments {
    /// All fields of a record that `words`, `findings`, or `textGaps` depend on.
    struct Inputs: Equatable {
        let id: Entry.ID
        let paragraphStarts: [Int]
        let decoded: [Segment]
        let showsCredits: Bool
        let state: Entry.State
        let skipsSilence: Bool
        let duration: TimeInterval?

        init(_ entry: Entry) {
            id = entry.id
            paragraphStarts = entry.paragraphs.map(\.start)
            decoded = entry.decoded
            showsCredits = entry.showsCredits
            state = entry.state
            skipsSilence = entry.skipsSilence
            duration = entry.duration
        }

        func wordsChanged(from other: Inputs) -> Bool {
            id != other.id || paragraphStarts != other.paragraphStarts || decoded != other.decoded
                || showsCredits != other.showsCredits
        }

        func findingsChanged(from other: Inputs) -> Bool {
            id != other.id || decoded != other.decoded || showsCredits != other.showsCredits
        }

        func gapsChanged(from other: Inputs) -> Bool {
            id != other.id || decoded != other.decoded || state != other.state
                || skipsSilence != other.skipsSilence || duration != other.duration
        }
    }

    /// All that `AppModel.canRebuildParagraphs` and offering a rebuild read.
    /// Paragraph text is carried only when a rebuild could still depend on
    /// matching course corrections, so ordinary edits compare empty arrays.
    private struct RebuildFacts: Equatable {
        let id: Entry.ID
        let paragraphs: [Transcript.Paragraph]
        let original: [Transcript.Paragraph]
        let isEdited: Bool
        let courseCorrections: [CourseCorrection]?
        let canUndo: Bool
        let isRunning: Bool
        let offersRebuild: Bool

        init(entry: Entry, canUndo: Bool, isRunning: Bool, offersRebuild: Bool) {
            id = entry.id
            let needsText =
                offersRebuild && !isRunning && !canUndo && entry.isEdited
                && !(entry.courseCorrections ?? []).isEmpty
            paragraphs = needsText ? entry.paragraphs : []
            original = needsText ? entry.original : []
            isEdited = entry.isEdited
            courseCorrections = needsText ? entry.courseCorrections : nil
            self.canUndo = canUndo
            self.isRunning = isRunning
            self.offersRebuild = offersRebuild
        }
    }

    /// What the page looks for its recording and its last export again on: a
    /// change of the record's files, or one of the moments `AppModel.fileChanges`
    /// counts, among them an export written again where the last one was,
    /// which leaves the record's files as they were.
    private struct Files: Equatable {
        let id: Entry.ID
        let recording: URL
        let bookmark: Data?
        let saved: [URL]
        let changes: Int

        init(_ entry: Entry, changes: Int) {
            id = entry.id
            recording = entry.recording
            bookmark = entry.bookmark
            saved = entry.saved
            self.changes = changes
        }
    }

    private(set) var words: [[Segment.Word]] = []
    private(set) var findings = Entry.Findings(
        repetitionWarning: nil, repeats: [], hiddenCredits: [], shortenedLoops: [])
    private(set) var textGaps: [ClosedRange<TimeInterval>] = []
    private(set) var hasTimedWords = false
    /// Whether what a warning offers to rebuild can be. Worked out as what it
    /// hangs on changes, since the answer can run the course corrections over
    /// the whole text, which neither hovering nor the warnings' two views repeat.
    private(set) var canRebuild = false
    /// Whether the recording is where the record says, and the file the last
    /// export wrote while it is still there. Looked for again when the record's
    /// files change and when the system says a file may have come back
    /// (`AppModel.fileChanges`), not at each draw: looking resolves the
    /// recording's bookmark.
    private(set) var hasRecording = false
    private(set) var lastExport: URL?
    private var loadedInputs: Inputs?
    private var loadedRebuild: RebuildFacts?
    private var loadedFiles: Files?

    func update(for entry: Entry, model: AppModel) {
        // Besides the record, what whether a warning's rebuild can run hangs on.
        let isRunning = model.busyEntry == entry.id
        let canUndo = model.canUndo(entry.id)
        let inputs = Inputs(entry)
        let previous = loadedInputs
        if previous?.wordsChanged(from: inputs) ?? true {
            words = WordLayout.grouped(entry.shown, into: entry.paragraphs)
            hasTimedWords = words.contains { !$0.isEmpty }
        }
        if previous?.findingsChanged(from: inputs) ?? true {
            findings = entry.findings
        }
        if previous?.gapsChanged(from: inputs) ?? true {
            textGaps = entry.textGaps
        }
        loadedInputs = inputs

        let files = Files(entry, changes: model.fileChanges)
        if loadedFiles != files {
            loadedFiles = files
            hasRecording = entry.hasRecording
            lastExport = model.lastExport(of: entry)
        }

        let rebuild = RebuildFacts(
            entry: entry, canUndo: canUndo, isRunning: isRunning,
            offersRebuild: findings.offersRebuild)
        if loadedRebuild != rebuild {
            loadedRebuild = rebuild
            canRebuild = rebuild.offersRebuild && model.canRebuildParagraphs(of: entry)
        }
    }
}

/// Formats a duration for display, such as recording length or time spent transcribing.
func formattedDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
}
