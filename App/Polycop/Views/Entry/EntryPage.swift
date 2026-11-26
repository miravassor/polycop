// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The transcript page's structure: title, toolbar tools, inspector, focused
/// values, confirmation dialogs, and page interaction state. Given only facts
/// a correction typed in the text leaves equal, so `EntryText` below redraws
/// the text without rebuilding the toolbar or the inspector.
struct EntryPage: View {
    let model: AppModel
    let facts: Facts
    let segments: PageSegments

    /// What the page's structure shows of the transcript, which a correction
    /// typed in the text leaves as it is.
    struct Facts: Equatable {
        var id: Entry.ID
        var name: String
        var tools: EntryTools.Facts
        var inspector: EntryInspector.Facts
        var steps: ParagraphSteps.Facts
    }

    @State private var pointer = ParagraphPointer()
    @State private var navigation = PageNavigationState()
    @State private var find = TranscriptFind()
    @FocusState private var isSearchFocused: Bool
    @State private var confirmingRemoval = false
    @State private var confirmingRevert = false

    private var reading: ReadingSettings { model.reading }

    /// Twice the reading width when the original shows beside the text.
    private var readingWidth: CGFloat {
        EntryView.readingWidth(textSize: reading.textSize) * (reading.isComparing ? 2 : 1)
    }

    private var following: Following {
        reading.following.effective(hasTimedWords: facts.steps.hasTimedWords)
    }

    private var page: PageNavigation {
        PageNavigation(state: navigation, following: following, player: model.player)
    }

    private var steps: ParagraphSteps {
        ParagraphSteps(model: model, facts: facts.steps, state: navigation)
    }

    var body: some View {
        // For RedrawTests, in the test host only, with the pointer they move.
        let _ = Redraws.count(.page, in: model)
        let _ = Redraws.keep(pointer, of: model)
        EntryText(
            model: model, checks: facts.inspector.checks, steps: facts.steps,
            segments: segments, pointer: pointer, navigation: navigation,
            find: $find, isSearchFocused: $isSearchFocused
        )
        // A reading column: a wide window adds margins, not longer lines.
        .frame(maxWidth: readingWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.page)
        .padding(.top, Spacing.block)
        .libraryWarnings(model)
        .navigationTitle(facts.name)
        .toolbar { pageTools }
        .modifier(InspectorToggle(isShown: Bindable(model.layout).showsInspector))
        .inspector(isPresented: Bindable(model.layout).showsInspector) { inspector }
        // The Playback menu's steps and File menu transcript commands, which
        // work with the inspector and sidebar hidden.
        .focusedSceneValue(\.paragraphSteps, steps)
        .focusedSceneValue(\.comparesOriginal, Bindable(reading).isComparing)
        .focusedSceneValue(\.selectedTranscripts, [facts.id])
        .onChange(of: find.query) { refreshSearch() }
        .onChange(of: find.isShown) { _, isShown in
            if isShown { isSearchFocused = true } else { find.close() }
        }
        .onChange(of: model.player.isOpen) { _, isOpen in
            if !isOpen { navigation.isFollowSuspended = false }
        }
        // A choice made while the page stood still is a request to follow.
        .onChange(of: reading.following) { navigation.isFollowSuspended = false }
        .confirmationDialog(
            "Throw away every correction of this transcript?", isPresented: $confirmingRevert
        ) {
            Button("Revert to Original", role: .destructive) { model.revert(facts.id) }
        } message: {
            Text(
                "The text goes back to what the engine wrote. Files already exported stay as they are, and a correction can be stepped back one at a time instead."
            )
        }
        .confirmationDialog(
            "Remove this transcript from the library?", isPresented: $confirmingRemoval
        ) {
            Button("Remove Transcript", role: .destructive) { model.removeEntry(facts.id) }
        } message: {
            Text(
                "It moves to Recently Deleted, with its corrections, for 30 days. Audio files and exports are kept."
            )
        }
    }

    /// Above the text they act on, the inspector's button alone at the
    /// trailing edge.
    @ToolbarContentBuilder private var pageTools: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            EntryTools(
                model: model, id: facts.id, facts: facts.tools, page: page,
                find: $find, isSearchFocused: $isSearchFocused,
                confirmingRevert: $confirmingRevert, confirmingRemoval: $confirmingRemoval)
        }
    }

    /// The recording, the warnings and the export, beside the text in the
    /// system's inspector, which the reader hides or shows.
    private var inspector: some View {
        EntryInspector(model: model, facts: facts.inspector)
            .modifier(InspectorColumn(layout: model.layout))
    }

    private func refreshSearch() {
        guard let paragraphs = model.entry(facts.id)?.paragraphs else { return }
        find.refresh(in: paragraphs, startingOver: true)
        if let current = find.current { page.show(current.paragraph) }
    }
}

extension EntryPage.Facts {
    init(
        entry: Entry, hasRecording: Bool, hasTimedWords: Bool,
        inspector: EntryInspector.Facts, model: AppModel
    ) {
        self.init(
            id: entry.id,
            name: entry.name,
            tools: EntryTools.Facts(
                entry: entry, hasRecording: hasRecording, hasTimedWords: hasTimedWords,
                hasExport: inspector.export.lastExport != nil, model: model),
            inspector: inspector,
            steps: ParagraphSteps.Facts(
                entry: entry, hasRecording: hasRecording, hasTimedWords: hasTimedWords))
    }
}

/// The transcript's content below the page's structure: progress, notices,
/// Find, the editable text, and the floating player. Reads the record itself
/// so edits redraw here without running `EntryPage`.
private struct EntryText: View {
    let model: AppModel
    let checks: TextChecks.Facts
    let steps: ParagraphSteps.Facts
    let segments: PageSegments
    let pointer: ParagraphPointer
    let navigation: PageNavigationState
    @Binding var find: TranscriptFind
    var isSearchFocused: FocusState<Bool>.Binding

    private var reading: ReadingSettings { model.reading }
    private var following: Following {
        reading.following.effective(hasTimedWords: steps.hasTimedWords)
    }

    private var page: PageNavigation {
        PageNavigation(state: navigation, following: following, player: model.player)
    }

    private var paragraphSteps: ParagraphSteps {
        ParagraphSteps(model: model, facts: steps, state: navigation)
    }

    var body: some View {
        if let entry = model.entry(steps.id) {
            let isRunning = model.busyEntry == entry.id
            VStack(alignment: .leading, spacing: Spacing.block) {
                Group {
                    EntryProgress(model: model, entry: entry, isRunning: isRunning)
                    EntryNotices(
                        entry: entry, checks: checks, hasRecording: steps.hasRecording,
                        model: model)
                    unsaved(for: entry, isRunning: isRunning)
                }
                .frame(maxWidth: .infinity)
                if !entry.paragraphs.isEmpty { findBar(for: entry, isRunning: isRunning) }
                transcript(for: entry, isRunning: isRunning)
            }
            .onChange(of: entry.paragraphs) {
                // Nothing to find: left as it is, so that typing does not update
                // what reads it, the toolbar's Find among them.
                if !find.query.isEmpty {
                    find.refresh(in: entry.paragraphs, startingOver: false)
                }
                if let activeParagraph = navigation.activeParagraph,
                    !entry.paragraphs.indices.contains(activeParagraph)
                {
                    navigation.activeParagraph = nil
                }
            }
        }
    }

    @ViewBuilder private func transcript(for entry: Entry, isRunning: Bool) -> some View {
        if entry.paragraphs.isEmpty {
            EntryEmptyState(model: model, entry: entry, isRunning: isRunning)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            playerBar(for: entry).padding(.bottom, PlayerBar.foot)
        } else {
            let words =
                segments.loadedInputs == nil
                ? WordLayout.grouped(entry.shown, into: entry.paragraphs) : segments.words
            TranscriptView(
                paragraphs: entry.paragraphs, resumed: entry.resumedParagraphs,
                player: model.player, isEditable: !isRunning,
                play: { model.replay(entry.id, from: $0) },
                edit: { model.edit(entry.id, paragraphAt: $0, text: $1) },
                typing: { model.player.pauseForTyping() },
                original: entry.original, isComparing: reading.isComparing,
                isFollowing: following != .off && !navigation.isFollowSuspended,
                suspendFollowing: page.suspendFollowing,
                suspendForEditing: {
                    if following.stopsWhenEditing { page.suspendFollowing() }
                },
                jump: Bindable(navigation).jump, showAtTop: Bindable(navigation).showAtTop,
                start: entry.readingParagraph,
                scrolled: { model.readingParagraph = $0 }, pointer: pointer, size: reading.textSize,
                active: navigation.activeParagraph,
                activate: {
                    if navigation.activeParagraph != $0 { navigation.activeParagraph = $0 }
                },
                review: entry.reviewParagraphs,
                toggleReview: { model.toggleReview(entry.id, paragraphAt: $0) },
                matches: find.matches, currentMatch: find.current,
                words: words,
                showsUncertainWords: reading.showsUncertainWords,
                cursorFollows: following == .cursor
            )
            // As in Music, the player floats at the foot of the text, which
            // scrolls under it; Find stays at the top, away from it.
            .floatingBar { playerBar(for: entry).padding(.bottom, PlayerBar.foot) }
        }
    }

    private func playerBar(for entry: Entry) -> some View {
        PlayerBar(
            player: model.player,
            marks: entry.paragraphs.map(\.seconds),
            pointer: pointer,
            isFollowSuspended: navigation.isFollowSuspended,
            length: entry.duration ?? 0,
            resume: entry.playbackPosition ?? 0,
            play: { model.replay(entry.id, from: $0, leadIn: 0) },
            jump: { navigation.jump = $0 },
            // Steps read the paragraph starts, which the player compares, so
            // one kept from an earlier draw steps through the same paragraphs.
            step: { paragraphSteps.step(by: $0) },
            returnToPlayback: { paragraphSteps.returnToPlayback() }
        )
        .equatable()
    }

    /// Saving is the rule and goes unsaid; a library that could not be
    /// written says so.
    @ViewBuilder private func unsaved(for entry: Entry, isRunning: Bool) -> some View {
        if !isRunning && !entry.paragraphs.isEmpty && model.hasUnsavedHistory
            && model.storageFailure == nil
        {
            Notice("Library has unsaved changes", .warning)
                .statusCapsule()
        }
    }

    @ViewBuilder private func findBar(for entry: Entry, isRunning: Bool) -> some View {
        if find.isShown {
            EntryFindBar(
                model: model, entry: entry, isRunning: isRunning, find: $find,
                isFocused: isSearchFocused, navigate: { navigateMatch(forward: $0) })
        }
    }

    private func navigateMatch(forward: Bool) {
        guard !find.matches.isEmpty else { return }
        find.step(forward: forward)
        if let current = find.current { page.show(current.paragraph) }
    }
}

#Preview {
    // An empty library and glossaries of its own, never the user's.
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let model = AppModel(
        history: folder.appending(path: "History"),
        glossaries: folder.appending(path: "Glossaries"),
        defaults: MemoryDefaults())
    var entry = Entry(
        recording: folder.appending(path: "Lecture.wav"),
        modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 4, text: "Bonjour à tous.")], partial: false)
    entry.state = .finished
    model.entries = [entry]
    return EntryView(model: model, id: entry.id)
}
