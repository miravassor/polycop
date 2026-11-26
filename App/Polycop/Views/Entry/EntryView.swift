// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
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
    /// Whether what a warning offers to rebuild can be. Worked out as what it
    /// hangs on changes, since the answer can run the course corrections over
    /// the whole text, which neither hovering nor the warnings' two views repeat.
    @State private var canRebuild: Bool?

    private var isRunning: Bool { model.busyEntry == entry.id }

    var body: some View {
        let currentFindings = segments.loadedInputs == nil ? entry.findings : segments.findings
        let currentTextGaps = segments.loadedInputs == nil ? entry.textGaps : segments.textGaps
        let currentHasTimedWords =
            segments.loadedInputs == nil
            ? PageSegments.initialHasTimedWords(for: entry) : segments.hasTimedWords
        let currentCanRebuild =
            canRebuild ?? (currentFindings.offersRebuild && model.canRebuildParagraphs(of: entry))
        let hasRecording = entry.hasRecording
        let lastExport = model.lastExport(of: entry)
        let inspectorFacts = EntryInspector.Facts(
            entry: entry, findings: currentFindings, textGaps: currentTextGaps,
            canRebuild: currentCanRebuild, lastExport: lastExport, model: model)
        let pageFacts = EntryPage.Facts(
            entry: entry, hasRecording: hasRecording, hasTimedWords: currentHasTimedWords,
            inspector: inspectorFacts, model: model)
        let segmentInputs = PageSegments.Inputs(entry)
        let rebuild = RebuildFacts(
            entry: entry, canUndo: model.canUndo(entry.id), isRunning: isRunning,
            offersRebuild: currentFindings.offersRebuild)

        EntryPage(model: model, facts: pageFacts, segments: segments)
            .onChange(of: segmentInputs, initial: true) { _, inputs in
                segments.update(for: entry, inputs: inputs)
            }
            .onChange(of: rebuild, initial: true) { _, facts in
                let next = facts.offersRebuild && model.canRebuildParagraphs(of: entry)
                if canRebuild != next { canRebuild = next }
            }
    }
}

extension LoadedEntryView {
    /// All that `AppModel.canRebuildParagraphs` and offering a rebuild read.
    /// Paragraph text is carried only when a rebuild could still depend on
    /// matching course corrections, so ordinary edits compare empty arrays.
    private struct RebuildFacts: Equatable {
        let paragraphs: [Transcript.Paragraph]
        let original: [Transcript.Paragraph]
        let isEdited: Bool
        let courseCorrections: [CourseCorrection]?
        let canUndo: Bool
        let isRunning: Bool
        let offersRebuild: Bool

        init(entry: Entry, canUndo: Bool, isRunning: Bool, offersRebuild: Bool) {
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
}

/// What a transcript's segments yield for the page: grouped timed words,
/// notices' findings, text gaps, and whether any word is timed. Updated only
/// from `EntryView`'s `onChange`, never during `body`, and read by `EntryView`
/// and `EntryText`, never by `EntryPage`.
@Observable
final class PageSegments {
    /// All fields of a record that `words`, `findings`, or `textGaps` depend on.
    struct Inputs: Equatable {
        let paragraphStarts: [Int]
        let decoded: [Segment]
        let showsCredits: Bool
        let state: Entry.State
        let skipsSilence: Bool
        let duration: TimeInterval?

        init(_ entry: Entry) {
            paragraphStarts = entry.paragraphs.map(\.start)
            decoded = entry.decoded
            showsCredits = entry.showsCredits
            state = entry.state
            skipsSilence = entry.skipsSilence
            duration = entry.duration
        }

        func wordsChanged(from other: Inputs) -> Bool {
            paragraphStarts != other.paragraphStarts || decoded != other.decoded
                || showsCredits != other.showsCredits
        }

        func findingsChanged(from other: Inputs) -> Bool {
            decoded != other.decoded || showsCredits != other.showsCredits
        }

        func gapsChanged(from other: Inputs) -> Bool {
            decoded != other.decoded || state != other.state || skipsSilence != other.skipsSilence
                || duration != other.duration
        }
    }

    var words: [[Segment.Word]] = []
    var findings = Entry.Findings(
        repetitionWarning: nil, repeats: [], hiddenCredits: [], shortenedLoops: [])
    var textGaps: [ClosedRange<TimeInterval>] = []
    var hasTimedWords = false
    /// Unobserved so reading whether the initial `onChange` has run adds no
    /// observation dependency during a view body.
    @ObservationIgnored private(set) var loadedInputs: Inputs?

    /// Matches `WordLayout.grouped(entry.shown, into: entry.paragraphs)` on
    /// the first pass before `onChange` groups the words.
    static func initialHasTimedWords(for entry: Entry) -> Bool {
        !entry.paragraphs.isEmpty && entry.shown.contains { !($0.words ?? []).isEmpty }
    }

    func update(for entry: Entry, inputs: Inputs) {
        let previous = loadedInputs
        loadedInputs = inputs
        if previous?.wordsChanged(from: inputs) ?? true {
            let grouped = WordLayout.grouped(entry.shown, into: entry.paragraphs)
            words = grouped
            let timed = grouped.contains { !$0.isEmpty }
            if hasTimedWords != timed { hasTimedWords = timed }
        }
        if previous?.findingsChanged(from: inputs) ?? true {
            let computed = entry.findings
            if findings != computed { findings = computed }
        }
        if previous?.gapsChanged(from: inputs) ?? true {
            let computed = entry.textGaps
            if textGaps != computed { textGaps = computed }
        }
    }
}

/// Formats a duration for display, such as recording length or time spent transcribing.
func formattedDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
}
