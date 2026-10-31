// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One transcript: the settings it came from, its progress while it runs, and
/// once done its text to listen to, correct and save.
struct EntryView: View {
    let model: AppModel
    let entry: Entry
    /// Whether the inspector beside the text shows, kept by the window.
    @Binding var showsInspector: Bool
    /// How wide the reader made the inspector, which the window's minimum
    /// width makes room for.
    @Binding var inspectorWidth: CGFloat
    @State private var focused: Int?
    @State private var activeParagraph: Int?
    @State private var find = TranscriptFind()
    @FocusState private var isSearchFocused: Bool
    @State private var isComparing = false
    @AppStorage(Following.key) private var following = Following.page
    @State private var isFollowSuspended = false
    @State private var jump: Int?
    @AppStorage("transcriptTextSize") private var size = EntryView.defaultTextSize
    @AppStorage("showsUncertainWords") private var showsUncertainWords = true
    /// The timed words of each paragraph, grouped when the paragraphs change
    /// rather than on every update of the page.
    @State private var words: [[Segment.Word]] = []
    /// The notices' findings, worked out when the segments change.
    @State private var findings: Entry.Findings?

    private var original: [Transcript.Paragraph] { entry.original }
    @State private var confirmingRemoval = false
    @State private var confirmingRevert = false

    private var isRunning: Bool { model.busyEntry == entry.id }
    /// What transcribed this entry, which decides what can be done with it.
    private var engine: Engine? { ModelCatalog.model(entry.modelFile)?.engine }

    var body: some View {
        // The player opens the page, as far under the toolbar as the next
        // block is under it; the text scrolls below them all, never under.
        VStack(alignment: .leading, spacing: 16) {
            playerBar
            EntryProgress(model: model, entry: entry, isRunning: isRunning)
            EntryNotices(
                entry: entry, findings: findings ?? entry.findings, model: model,
                isRunning: isRunning, engine: engine)
            unsaved
            if !entry.paragraphs.isEmpty { findAndStatus }
            transcript
        }
        // A reading column: a wide window adds margins, not longer lines.
        .frame(maxWidth: readingWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .navigationTitle(entry.name)
        .toolbar { pageTools }
        .inspector(isPresented: $showsInspector) { inspector }
        // The Playback menu's steps, which work with the inspector hidden.
        .focusedSceneValue(\.paragraphSteps, steps)
        .focusedSceneValue(\.comparesOriginal, $isComparing)
        .onChange(of: find.query) { refreshSearch() }
        .onChange(of: model.player.isOpen) { _, isOpen in
            if !isOpen { isFollowSuspended = false }
        }
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
        .onChange(of: entry.paragraphs) {
            refreshSearch(navigate: false)
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
            placeholder
            Spacer(minLength: 0)
        } else {
            TranscriptView(
                paragraphs: entry.paragraphs, resumed: entry.resumedParagraphs,
                player: model.player, isEditable: !isRunning,
                play: { model.replay(entry.id, from: $0) },
                edit: { model.edit(entry.id, paragraphAt: $0, text: $1) },
                typing: { model.player.pauseForTyping() },
                hover: { focused = $0 },
                original: original, isComparing: isComparing,
                isFollowing: following != .off && !isFollowSuspended,
                suspendFollowing: suspendFollowing,
                suspendForEditing: {
                    if following.stopsWhenEditing { suspendFollowing() }
                },
                jump: $jump, start: entry.readingParagraph,
                scrolled: { model.readingParagraph = $0 }, focused: focused, size: size,
                active: activeParagraph,
                activate: { if activeParagraph != $0 { activeParagraph = $0 } },
                review: entry.reviewParagraphs,
                toggleReview: { model.toggleReview(entry.id, paragraphAt: $0) },
                matches: find.matches, currentMatch: find.current,
                words: words,
                showsUncertainWords: showsUncertainWords
            )
        }
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
            jump: { jump = $0 })
    }

    /// Resizable as the library is: from the narrowest that keeps every label
    /// whole, Picture in Picture and Previous the longest, to room for a
    /// larger picture.
    static let inspectorWidths: ClosedRange<CGFloat> = 360...520
    static let idealInspectorWidth: CGFloat = 380

    /// Shown before there is any text, at the top of the page like everything
    /// else rather than floating in the middle of it.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                entry.state == .finished
                    ? "No text was detected" : "Your transcript will appear here"
            )
            .font(.headline)
            Text(
                entry.state == .finished
                    ? "Listen to the recording to check that it contains audible speech."
                    : "Text is kept in your library when transcription finishes or pauses."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    /// Saving is the rule and goes unsaid; a library that could not be
    /// written says so.
    @ViewBuilder private var unsaved: some View {
        if !isRunning && !entry.paragraphs.isEmpty
            && (model.hasUnsavedHistory || model.storageFailure != nil)
        {
            Label("Library has unsaved changes", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .notice(.orange)
        }
    }

    /// Twice the reading width when the original shows beside the text.
    private var readingWidth: CGFloat {
        Self.readingWidth(textSize: size) * (isComparing ? 2 : 1)
    }

    static let defaultTextSize = 13.0

    /// About 75 characters a line, times included, at a text size.
    static func readingWidth(textSize: Double) -> CGFloat { 40 * textSize + 160 }

    /// The page's tools in the window's toolbar, each also reachable by its
    /// shortcut; the actions on the whole transcript in its More menu.
    @ToolbarContentBuilder private var pageTools: some ToolbarContent {
        // Above the text they act on, the inspector's button alone at the
        // trailing edge.
        if !entry.paragraphs.isEmpty {
            ToolbarItemGroup(placement: .principal) {
                compareToggle
                reviewMenu
                findButton
                textMenu
            }
        }
        ToolbarItem(placement: .principal) {
            EntryActionsMenu(
                model: model, entry: entry, isRunning: isRunning,
                confirmingRevert: $confirmingRevert, confirmingRemoval: $confirmingRemoval,
                exportAs: { EntryExportSection.exportAs(entry, with: model) })
        }
    }

    @ViewBuilder private var findAndStatus: some View {
        if find.isShown {
            EntryFindBar(
                model: model, entry: entry, isRunning: isRunning, find: $find,
                isFocused: $isSearchFocused, navigate: { navigateMatch(forward: $0) })
        }
        if isRunning {
            Text("Transcription in progress. Editing is available when it stops.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One switch rather than two choices: the original beside the text, or not.
    private var compareToggle: some View {
        Toggle(isOn: $isComparing) {
            Label("Compare", systemImage: "rectangle.split.2x1")
        }
        .help(isComparing ? "Show your text alone" : "Show the original beside your text")
    }

    private var reviewMenu: some View {
        Menu {
            Button("Previous Flagged Passage") { navigateReview(forward: false) }
                .disabled(entry.reviewParagraphs.isEmpty)
            Button("Next Flagged Passage") { navigateReview(forward: true) }
                .disabled(entry.reviewParagraphs.isEmpty)
            Divider()
            Text("Use the flag beside a paragraph to review it later.")
        } label: {
            Label("Review (\(entry.reviewParagraphs.count))", systemImage: "flag")
        }
        .help("Flagged passages: \(entry.reviewParagraphs.count)")
    }

    private var textMenu: some View {
        Menu {
            Button("Undo Last Correction") { model.undo(entry.id) }
                .disabled(isRunning || !model.canUndo(entry.id))
            Button("Find and Replace") {
                find.isShown = true
                find.isReplacing = true
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Toggle("Underline Uncertain Words", isOn: $showsUncertainWords)
            Divider()
            Button("Smaller Text") { size = max(10, size - 1) }
                .keyboardShortcut("-")
                .disabled(size <= 10)
            Button("Larger Text") { size = min(28, size + 1) }
                .keyboardShortcut("+")
                .disabled(size >= 28)
        } label: {
            Label("Text", systemImage: "textformat.size")
        }
        .menuIndicator(.hidden)
        .help("Text size and correction history")
    }

    private var findButton: some View {
        Button {
            find.isShown = true
            isSearchFocused = true
        } label: {
            Label("Find", systemImage: "magnifyingglass")
        }
        .keyboardShortcut("f")
    }

    private func refreshSearch(navigate: Bool = true) {
        find.refresh(in: entry.paragraphs, startingOver: navigate)
        if navigate, let current = find.current { show(current.paragraph) }
    }

    private func regroupWords() {
        words = WordLayout.grouped(entry.shown, into: entry.paragraphs)
    }

    /// Stops following while the reader looks elsewhere, and offers the way back.
    private func suspendFollowing() {
        guard following != .off, !isFollowSuspended else { return }
        isFollowSuspended = true
    }

    private func navigateMatch(forward: Bool) {
        guard !find.matches.isEmpty else { return }
        find.step(forward: forward)
        if let current = find.current { show(current.paragraph) }
    }

    private func navigateReview(forward: Bool) {
        let indices = entry.reviewParagraphs.sorted()
        let next =
            forward
            ? indices.first { $0 > (activeParagraph ?? -1) } ?? indices.first
            : indices.last { $0 < (activeParagraph ?? entry.paragraphs.count) } ?? indices.last
        guard let next else { return }
        show(next)
    }

    /// Brings a paragraph into view and makes it the active one, leaving
    /// playback to be followed again later.
    private func show(_ paragraph: Int) {
        suspendFollowing()
        activeParagraph = paragraph
        jump = paragraph
    }
}

extension EntryView {
    /// The recording and the export, beside the text in the system's inspector,
    /// which the reader hides or shows.
    private var inspector: some View {
        EntryInspector(
            model: model, entry: entry, steps: steps, following: $following,
            isFollowSuspended: $isFollowSuspended,
            hasTimedWords: words.contains { !$0.isEmpty }, isRunning: isRunning, engine: engine
        )
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            inspectorWidth = max($0, Self.inspectorWidths.lowerBound)
        }
        // Starting where the reader left it: each transcript has a page, and
        // so an inspector, of its own.
        .inspectorColumnWidth(
            min: Self.inspectorWidths.lowerBound, ideal: inspectorWidth,
            max: Self.inspectorWidths.upperBound
        )
        .modifier(InspectorToggle(isShown: $showsInspector))
    }

    private var steps: ParagraphSteps {
        ParagraphSteps(model: model, entry: entry, activeParagraph: $activeParagraph, jump: $jump)
    }
}

/// Formats a duration for display, such as recording length or time spent transcribing.
func formattedDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
}
