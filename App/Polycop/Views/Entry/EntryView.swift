// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One transcript: the settings it came from, its progress while it runs, and
/// once done its text to listen to, correct and save.
struct EntryView: View {
    let model: AppModel
    let entry: Entry
    @State private var focused: Int?
    @State private var activeParagraph: Int?
    @State private var find = TranscriptFind()
    @FocusState private var isSearchFocused: Bool
    @State private var isFollowSuspended = false
    @State private var jump: Int?
    @State private var showAtTop: Int?
    /// The timed words of each paragraph, grouped when the paragraphs change
    /// rather than on every update of the page.
    @State private var words: [[Segment.Word]] = []
    /// The notices' findings, worked out when the segments change.
    @State private var findings: Entry.Findings?
    /// Whether what a warning offers to rebuild can be. Worked out as what it
    /// hangs on changes, since the answer can run the course corrections over
    /// the whole text, which neither hovering nor the warnings' two views repeat.
    @State private var canRebuild = false

    private var original: [Transcript.Paragraph] { entry.original }
    @State private var confirmingRemoval = false
    @State private var confirmingRevert = false

    private var isRunning: Bool { model.busyEntry == entry.id }
    private var reading: ReadingSettings { model.reading }
    /// What transcribed this entry, which decides what can be done with it.
    private var engine: Engine? { ModelCatalog.model(entry.modelFile)?.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.block) {
            Group {
                EntryProgress(model: model, entry: entry, isRunning: isRunning)
                EntryNotices(
                    entry: entry, findings: findings ?? entry.findings, canRebuild: canRebuild,
                    model: model, isRunning: isRunning, engine: engine)
                unsaved
            }
            .frame(maxWidth: .infinity)
            if !entry.paragraphs.isEmpty { findBar }
            transcript
        }
        // A reading column: a wide window adds margins, not longer lines.
        .frame(maxWidth: readingWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.page)
        .padding(.top, Spacing.block)
        .libraryWarnings(model)
        .navigationTitle(entry.name)
        .toolbar { pageTools }
        .modifier(InspectorToggle(isShown: Bindable(model.layout).showsInspector))
        .inspector(isPresented: Bindable(model.layout).showsInspector) { inspector }
        // The Playback menu's steps, which work with the inspector hidden.
        .focusedSceneValue(\.paragraphSteps, steps)
        .focusedSceneValue(\.comparesOriginal, Bindable(reading).isComparing)
        .onChange(of: find.query) { refreshSearch() }
        .onChange(of: find.isShown) { _, isShown in
            if isShown { isSearchFocused = true } else { find.close() }
        }
        .onChange(of: model.player.isOpen) { _, isOpen in
            if !isOpen { isFollowSuspended = false }
        }
        // A choice made while the page stood still is a request to follow.
        .onChange(of: reading.following) { isFollowSuspended = false }
        // Words hang on the segments and on where paragraphs open, which
        // typing leaves alone, so they are not regrouped at each key.
        .onChange(of: entry.paragraphs.map(\.start), initial: true) { regroupWords() }
        .onChange(of: entry.decoded, initial: true) {
            regroupWords()
            findings = entry.findings
        }
        .onChange(of: entry.showsCredits) {
            regroupWords()
            findings = entry.findings
        }
        .onChange(of: rebuildFacts, initial: true) {
            canRebuild = rebuildFacts.offersRebuild && model.canRebuildParagraphs(of: entry)
        }
        .onChange(of: entry.paragraphs) {
            // Nothing to find: left as it is, so that typing does not update
            // what reads it, the toolbar's Find among them.
            if !find.query.isEmpty { refreshSearch(navigate: false) }
            if let activeParagraph, !entry.paragraphs.indices.contains(activeParagraph) {
                self.activeParagraph = nil
            }
        }
        .confirmationDialog(
            "Throw away every correction of this transcript?", isPresented: $confirmingRevert
        ) {
            Button("Revert to Original", role: .destructive) { model.revert(entry.id) }
        } message: {
            Text(
                "The text goes back to what the engine wrote. Files already exported stay as they are, and a correction can be stepped back one at a time instead."
            )
        }
        .confirmationDialog(
            "Remove this transcript from the library?", isPresented: $confirmingRemoval
        ) {
            Button("Remove Transcript", role: .destructive) { model.removeEntry(entry.id) }
        } message: {
            Text(
                "It moves to Recently Deleted, with its corrections, for 30 days. Audio files and exports are kept."
            )
        }
    }

    @ViewBuilder private var transcript: some View {
        if entry.paragraphs.isEmpty {
            EntryEmptyState(model: model, entry: entry, isRunning: isRunning)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            playerBar.padding(.bottom, PlayerBar.foot)
        } else {
            TranscriptView(
                paragraphs: entry.paragraphs, resumed: entry.resumedParagraphs,
                player: model.player, isEditable: !isRunning,
                play: { model.replay(entry.id, from: $0) },
                edit: { model.edit(entry.id, paragraphAt: $0, text: $1) },
                typing: { model.player.pauseForTyping() },
                hover: { focused = $0 },
                original: original, isComparing: reading.isComparing,
                isFollowing: following != .off && !isFollowSuspended,
                suspendFollowing: page.suspendFollowing,
                suspendForEditing: {
                    if following.stopsWhenEditing { page.suspendFollowing() }
                },
                jump: $jump, showAtTop: $showAtTop, start: entry.readingParagraph,
                scrolled: { model.readingParagraph = $0 }, focused: focused, size: reading.textSize,
                active: activeParagraph,
                activate: { if activeParagraph != $0 { activeParagraph = $0 } },
                review: entry.reviewParagraphs,
                toggleReview: { model.toggleReview(entry.id, paragraphAt: $0) },
                matches: find.matches, currentMatch: find.current,
                words: words,
                showsUncertainWords: reading.showsUncertainWords,
                cursorFollows: following == .cursor
            )
            // As in Music, the player floats at the foot of the text, which
            // scrolls under it; Find stays at the top, away from it.
            .floatingBar {
                VStack(spacing: 8) {
                    if isFollowSuspended { returnToPlayback }
                    playerBar
                }
                .padding(.bottom, PlayerBar.foot)
            }
        }
    }

    /// Above the player, so that the text stays in place, and only once the
    /// page has stopped following.
    private var returnToPlayback: some View {
        Button {
            steps.returnToPlayback()
        } label: {
            Label("Return to Playback", systemImage: "arrow.uturn.backward")
                .statusCapsule()
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Bring the paragraph playing to the top, and follow it again (Option-Command-L)")
    }

    private var playerBar: some View {
        PlayerBar(
            player: model.player,
            marks: entry.paragraphs.map(\.seconds),
            highlighted: focused,
            length: entry.duration ?? 0,
            resume: entry.playbackPosition ?? 0,
            play: { model.replay(entry.id, from: $0, leadIn: 0) },
            hover: { focused = $0 },
            jump: { jump = $0 },
            // Steps read the paragraph starts, which the player compares, so
            // one kept from an earlier draw steps through the same paragraphs.
            step: { steps.step(by: $0) }
        )
        .equatable()
    }

    /// Resizable as the library is: from the narrowest that keeps every label
    /// whole to room for a larger picture.
    static let inspectorWidths: ClosedRange<CGFloat> = 360...520
    static let idealInspectorWidth: CGFloat = 380

    /// Saving is the rule and goes unsaid; a library that could not be
    /// written says so.
    @ViewBuilder private var unsaved: some View {
        if !isRunning && !entry.paragraphs.isEmpty && model.hasUnsavedHistory
            && model.storageFailure == nil
        {
            Notice("Library has unsaved changes", .warning)
                .statusCapsule()
        }
    }

    /// Twice the reading width when the original shows beside the text.
    private var readingWidth: CGFloat {
        Self.readingWidth(textSize: reading.textSize) * (reading.isComparing ? 2 : 1)
    }

    /// About 75 characters a line, times included, at a text size.
    static func readingWidth(textSize: Double) -> CGFloat { 40 * textSize + 160 }

    /// Above the text they act on, the inspector's button alone at the
    /// trailing edge.
    @ToolbarContentBuilder private var pageTools: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            EntryTools(
                model: model, id: entry.id, facts: toolFacts, page: page,
                find: $find, isSearchFocused: $isSearchFocused,
                confirmingRevert: $confirmingRevert, confirmingRemoval: $confirmingRemoval)
        }
    }

    private var toolFacts: EntryTools.Facts {
        EntryTools.Facts(
            paragraphCount: entry.paragraphs.count, flagged: entry.reviewParagraphs.sorted(),
            canUndo: model.canUndo(entry.id), isEdited: entry.isEdited,
            hasRecording: entry.hasRecording, hasTimedWords: hasTimedWords,
            hasExport: model.lastExport(of: entry) != nil,
            isRunning: isRunning)
    }

    @ViewBuilder private var findBar: some View {
        if find.isShown {
            EntryFindBar(
                model: model, entry: entry, isRunning: isRunning, find: $find,
                isFocused: $isSearchFocused, navigate: { navigateMatch(forward: $0) })
        }
    }

    private func refreshSearch(navigate: Bool = true) {
        find.refresh(in: entry.paragraphs, startingOver: navigate)
        if navigate, let current = find.current { page.show(current.paragraph) }
    }

    private func regroupWords() {
        words = WordLayout.grouped(entry.shown, into: entry.paragraphs)
    }

    private func navigateMatch(forward: Bool) {
        guard !find.matches.isEmpty else { return }
        find.step(forward: forward)
        if let current = find.current { page.show(current.paragraph) }
    }
}

extension EntryView {
    /// All that `AppModel.canRebuildParagraphs` and offering a rebuild read.
    private struct RebuildFacts: Equatable {
        let paragraphs: [Transcript.Paragraph]
        let original: [Transcript.Paragraph]
        let isEdited: Bool
        let courseCorrections: [CourseCorrection]?
        let canUndo: Bool
        let isRunning: Bool
        let offersRebuild: Bool
    }

    private var rebuildFacts: RebuildFacts {
        RebuildFacts(
            paragraphs: entry.paragraphs, original: original, isEdited: entry.isEdited,
            courseCorrections: entry.courseCorrections, canUndo: model.canUndo(entry.id),
            isRunning: isRunning, offersRebuild: findings?.offersRebuild ?? false)
    }

    /// The recording, the warnings and the export, beside the text in the
    /// system's inspector, which the reader hides or shows.
    private var inspector: some View {
        EntryInspector(
            model: model, entry: entry, findings: findings ?? entry.findings,
            canRebuild: canRebuild, isRunning: isRunning, engine: engine
        )
        .modifier(InspectorColumn(layout: model.layout))
    }

    private var hasTimedWords: Bool { words.contains { !$0.isEmpty } }
    private var following: Following {
        reading.following.effective(hasTimedWords: hasTimedWords)
    }

    private var page: PageNavigation {
        PageNavigation(
            activeParagraph: $activeParagraph, jump: $jump,
            isFollowSuspended: $isFollowSuspended, following: following,
            player: model.player)
    }

    private var steps: ParagraphSteps {
        ParagraphSteps(
            model: model, entry: entry, activeParagraph: $activeParagraph, jump: $jump,
            showAtTop: $showAtTop, isFollowSuspended: $isFollowSuspended,
            hasTimedWords: hasTimedWords)
    }
}

/// Formats a duration for display, such as recording length or time spent transcribing.
func formattedDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
}
