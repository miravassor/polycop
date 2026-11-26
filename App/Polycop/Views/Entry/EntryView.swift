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
        segments.update(for: entry, model: model)
        let hasRecording = entry.hasRecording
        let lastExport = model.lastExport(of: entry)
        let inspectorFacts = EntryInspector.Facts(
            entry: entry, findings: segments.findings, textGaps: segments.textGaps,
            canRebuild: segments.canRebuild, lastExport: lastExport, model: model)
        let pageFacts = EntryPage.Facts(
            entry: entry, hasRecording: hasRecording, hasTimedWords: segments.hasTimedWords,
            inspector: inspectorFacts, model: model)
        return EntryPage(model: model, facts: pageFacts, segments: segments)
    }
}

/// What a transcript's segments yield for the page: grouped timed words,
/// notices' findings, text gaps, whether any word is timed, and whether a
/// warning's rebuild can run. Updated synchronously by `LoadedEntryView` as
/// its inputs change and read by `LoadedEntryView` and `EntryText`, never by
/// `EntryPage`.
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

    private(set) var words: [[Segment.Word]] = []
    private(set) var findings = Entry.Findings(
        repetitionWarning: nil, repeats: [], hiddenCredits: [], shortenedLoops: [])
    private(set) var textGaps: [ClosedRange<TimeInterval>] = []
    private(set) var hasTimedWords = false
    /// Whether what a warning offers to rebuild can be. Worked out as what it
    /// hangs on changes, since the answer can run the course corrections over
    /// the whole text, which neither hovering nor the warnings' two views repeat.
    private(set) var canRebuild = false
    private var loadedInputs: Inputs?
    private var loadedRebuild: RebuildFacts?

    func update(for entry: Entry, model: AppModel) {
        // Always read so `LoadedEntryView.body` observes `busyEntry` and `undoable`.
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
