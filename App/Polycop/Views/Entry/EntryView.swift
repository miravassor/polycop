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
    @State private var isComparing = false
    @State private var isFollowing = false
    @State private var isFollowSuspended = false
    @State private var jump: Int?
    @AppStorage("transcriptTextSize") private var size = 13.0
    @AppStorage("showsUncertainWords") private var showsUncertainWords = true
    /// The timed words of each paragraph, grouped when the paragraphs change
    /// rather than on every update of the page.
    @State private var words: [[Segment.Word]] = []
    /// The notices' findings, worked out when the segments change.
    @State private var findings: Entry.Findings?

    private var original: [Transcript.Paragraph] { entry.original }
    @State private var confirmingRemoval = false
    @State private var confirmingRevert = false
    @State private var showingDetails = false

    private var isRunning: Bool { model.busyEntry == entry.id }
    /// What transcribed this entry, which decides what can be done with it.
    private var engine: Engine? { ModelCatalog.model(entry.modelFile)?.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            EntryProgress(model: model, entry: entry, isRunning: isRunning)
            EntryNotices(
                entry: entry, findings: findings ?? entry.findings, model: model,
                isRunning: isRunning, engine: engine)
            if entry.paragraphs.isEmpty {
                placeholder
                Spacer(minLength: 0)
            } else {
                editingTools
                TranscriptView(
                    paragraphs: entry.paragraphs, resumed: entry.resumedParagraphs,
                    player: model.player, isEditable: !isRunning,
                    play: { model.replay(entry.id, from: $0) },
                    edit: { model.edit(entry.id, paragraphAt: $0, text: $1) },
                    typing: { model.player.pauseForTyping() },
                    hover: { focused = $0 },
                    original: original, isComparing: isComparing, isFollowing: isFollowing,
                    suspendFollowing: suspendFollowing,
                    jump: $jump, start: entry.readingParagraph,
                    scrolled: { model.readingParagraph = $0 }, focused: focused, size: size,
                    active: activeParagraph,
                    activate: { if activeParagraph != $0 { activeParagraph = $0 } },
                    review: entry.reviewParagraphs,
                    toggleReview: { model.toggleReview(entry.id, paragraphAt: $0) },
                    matches: find.matches, currentMatch: find.current,
                    words: words,
                    showsUncertainWords: showsUncertainWords)
            }
            EntryAudio(
                model: model, entry: entry, focused: $focused,
                activeParagraph: $activeParagraph, jump: $jump, isFollowing: $isFollowing,
                isFollowSuspended: $isFollowSuspended)
            EntryExportCard(model: model, entry: entry, isRunning: isRunning, engine: engine)
        }
        .padding(28)
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
                "The transcript and its corrections will be removed. Audio files and exports are kept."
            )
        }
    }

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

    /// The settings the transcript came from, so a result can be judged later.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !isRunning && !entry.paragraphs.isEmpty {
                    if model.hasUnsavedHistory || model.storageFailure != nil {
                        Label(
                            "Library has unsaved changes", systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    } else {
                        Label("Saved in library", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            Spacer(minLength: 8)
            Button {
                showingDetails = true
            } label: {
                Image(systemName: "info.circle").frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .iconControl()
            .accessibilityLabel("Transcription details")
            .help("Model, language and transcription settings")
            .popover(isPresented: $showingDetails) {
                EntryDetailsPopover(entry: entry, engine: engine)
            }
            EntryActionsMenu(
                model: model, entry: entry, isRunning: isRunning,
                confirmingRevert: $confirmingRevert, confirmingRemoval: $confirmingRemoval,
                exportAs: { EntryExportCard.exportAs(entry, with: model) })
        }
    }

    private var editingTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    displayMode.fixedSize()
                    Spacer(minLength: 12)
                    readingActions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    displayMode
                    readingActions
                }
            }
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
    }

    private var displayMode: some View {
        // One choice of two, so one control that says which is chosen.
        Picker("Transcript view", selection: $isComparing) {
            Text("Your text").tag(false)
            Text("Compare original").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var readingActions: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Previous flagged passage") { navigateReview(forward: false) }
                    .disabled(entry.reviewParagraphs.isEmpty)
                Button("Next flagged passage") { navigateReview(forward: true) }
                    .disabled(entry.reviewParagraphs.isEmpty)
                Divider()
                Text("Use the flag beside a paragraph to review it later.")
            } label: {
                Label("Review (\(entry.reviewParagraphs.count))", systemImage: "flag")
            }
            .fixedSize()
            findButton
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
                Button("Smaller text") { size = max(10, size - 1) }
                    .keyboardShortcut("-")
                    .disabled(size <= 10)
                Button("Larger text") { size = min(28, size + 1) }
                    .keyboardShortcut("+")
                    .disabled(size >= 28)
            } label: {
                Image(systemName: "textformat.size").frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .iconControl()
            .accessibilityLabel("Text tools")
            .help("Text size and correction history")
        }
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
        guard isFollowing else { return }
        isFollowing = false
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

/// Formats a duration for display, such as recording length or time spent transcribing.
func formattedDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
}
