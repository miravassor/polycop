// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One transcript: the settings it came from, its progress while it runs, and
/// once done its text to listen to, correct and save.
struct EntryView: View {
    let model: AppModel
    let entry: Entry
    @State private var focused: Int?
    @State private var activeParagraph: Int?
    @State private var searching = false
    @State private var query = ""
    @State private var matches: [TranscriptSearch.Match] = []
    @State private var matchIndex = 0
    @State private var isReplacing = false
    @State private var replacement = ""
    @State private var remembersReplacement = false
    @FocusState private var isSearchFocused: Bool
    @State private var isComparing = false
    @State private var isFollowing = false
    @State private var isFollowSuspended = false
    @State private var jump: Int?
    @AppStorage("transcriptTextSize") private var size = 13.0
    @AppStorage("showsUncertainWords") private var showsUncertainWords = true

    private var original: [Transcript.Paragraph] { entry.original }
    @State private var confirmingRemoval = false
    @State private var confirmingRevert = false
    @State private var showingDetails = false
    @State private var showingExportOptions = false

    private var isRunning: Bool { model.busyEntry == entry.id }
    /// What transcribed this entry, which decides what can be done with it.
    private var engine: Engine? { ModelCatalog.model(entry.modelFile)?.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            state
            EntryNotices(entry: entry, model: model, isRunning: isRunning, engine: engine)
            if entry.paragraphs.isEmpty {
                placeholder
                Spacer(minLength: 0)
            } else {
                editingTools
                TranscriptView(
                    paragraphs: entry.paragraphs, resumed: entry.resumedParagraphs,
                    player: model.player, isEditable: !isRunning,
                    play: { model.replay(entry.id, from: $0) },
                    edit: {
                        model.player.pauseForTyping()
                        model.edit(entry.id, paragraphAt: $0, text: $1)
                    },
                    hover: { focused = $0 },
                    original: original, isComparing: isComparing, isFollowing: isFollowing,
                    suspendFollowing: {
                        if isFollowing {
                            isFollowing = false
                            isFollowSuspended = true
                        }
                    },
                    jump: $jump, focused: focused, size: size,
                    active: activeParagraph, activate: { activeParagraph = $0 },
                    review: entry.reviewParagraphs,
                    toggleReview: { model.toggleReview(entry.id, paragraphAt: $0) },
                    matches: matches, currentMatch: currentMatch,
                    words: WordLayout.grouped(entry.shown, into: entry.paragraphs),
                    showsUncertainWords: showsUncertainWords)
            }
            recording
            actions
        }
        .padding(28)
        .onChange(of: query) { refreshSearch() }
        .onChange(of: model.player.isOpen) { _, isOpen in
            if !isOpen { isFollowSuspended = false }
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
            .frame(width: 32, height: 28)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Transcription details")
            .help("Model, language and transcription settings")
            .popover(isPresented: $showingDetails) {
                EntryDetailsPopover(entry: entry, engine: engine)
            }
            EntryActionsMenu(
                model: model, entry: entry, isRunning: isRunning,
                confirmingRevert: $confirmingRevert, confirmingRemoval: $confirmingRemoval,
                exportAs: exportAs)
        }
    }

    private var editingTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
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
            if searching { searchBar }
            if isRunning {
                Text("Transcription in progress. Editing is available when it stops.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var displayMode: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { !isComparing }, set: { if $0 { isComparing = false } })) {
                Text("Your text").frame(width: 120)
            }
            Toggle(isOn: Binding(get: { isComparing }, set: { if $0 { isComparing = true } })) {
                Text("Compare original").frame(width: 120)
            }
        }
        .toggleStyle(.button)
        .controlSize(.regular)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript view")
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
                    searching = true
                    isReplacing = true
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
            .frame(width: 40, height: 24)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Text tools")
            .help("Text size and correction history")
        }
    }

    private var currentMatch: TranscriptSearch.Match? {
        matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
    }

    private var replayPassage: some View {
        Button {
            guard let activeParagraph, entry.paragraphs.indices.contains(activeParagraph) else {
                return
            }
            model.replay(
                entry.id, from: max(0, entry.paragraphs[activeParagraph].seconds - 2), leadIn: 0)
        } label: {
            Label("Replay passage", systemImage: "gobackward")
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(activeParagraph == nil || !entry.hasRecording)
        .help("Replay the active paragraph with two seconds of context (Option-Command-R)")
    }

    /// Plays the next or previous paragraph, counted from the one playing.
    private func paragraphStep(by offset: Int) -> some View {
        Button {
            let starts = entry.paragraphs.map(\.seconds)
            let current =
                model.player.isOpen
                ? TranscriptNavigation.paragraph(playingAt: model.player.position, starts: starts)
                : activeParagraph
            guard
                let next = TranscriptNavigation.paragraph(
                    from: current, offset: offset, count: starts.count)
            else { return }
            activeParagraph = next
            jump = next
            model.replay(entry.id, from: starts[next])
        } label: {
            Image(systemName: offset < 0 ? "chevron.up" : "chevron.down")
        }
        .keyboardShortcut(offset < 0 ? .upArrow : .downArrow, modifiers: [.command, .option])
        .disabled(!entry.hasRecording)
        .help(offset < 0 ? "Play the previous paragraph" : "Play the next paragraph")
        .accessibilityLabel(offset < 0 ? "Play the previous paragraph" : "Play the next paragraph")
    }

    private var findButton: some View {
        Button {
            searching = true
            isSearchFocused = true
        } label: {
            Label("Find", systemImage: "magnifyingglass")
        }
        .keyboardShortcut("f")
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            findRow
            if isReplacing { replaceRow }
        }
    }

    private var findRow: some View {
        HStack(spacing: 12) {
            TextField("Find in your text", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit { navigateMatch(forward: true) }
                .onExitCommand {
                    searching = false
                    query = ""
                }
            Text(
                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "" : matches.isEmpty ? "No results" : "\(matchIndex + 1) of \(matches.count)"
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize()
            Button {
                navigateMatch(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(matches.isEmpty)
            .accessibilityLabel("Previous search result")
            Button {
                navigateMatch(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g")
            .disabled(matches.isEmpty)
            .accessibilityLabel("Next search result")
            Toggle("Replace", isOn: $isReplacing)
                .toggleStyle(.checkbox)
            Button {
                searching = false
                query = ""
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close search")
        }
    }

    /// Replacement is literal, while finding ignores case and accents, so every
    /// spelling of a misheard word is replaced by the same correction.
    private var replaceRow: some View {
        HStack(spacing: 12) {
            TextField("Replace with", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .onSubmit(replaceCurrentMatch)
            Button("Replace", action: replaceCurrentMatch)
                .disabled(currentMatch == nil || isRunning)
            Button("Replace All") {
                if remembersReplacement {
                    model.remember(
                        CourseCorrection(
                            text: query.trimmingCharacters(in: .whitespacesAndNewlines),
                            replacement: replacement),
                        forCourseOf: entry.id)
                }
                model.replace(entry.id, matches: matches, with: replacement)
            }
            .disabled(matches.isEmpty || isRunning)
            .help("Replace every result. Undo Last Correction takes them all back.")
            if let course = entry.glossary {
                Toggle("Remember for \(course)", isOn: $remembersReplacement)
                    .toggleStyle(.checkbox)
                    .help("Replace All also corrects this course's next transcripts.")
            }
        }
    }

    private func replaceCurrentMatch() {
        guard let currentMatch else { return }
        model.replace(entry.id, matches: [currentMatch], with: replacement)
    }

    private func refreshSearch(navigate: Bool = true) {
        matches = TranscriptSearch.matches(in: entry.paragraphs, query: query)
        matchIndex = navigate ? 0 : min(matchIndex, max(0, matches.count - 1))
        if navigate, let currentMatch {
            isFollowing = false
            activeParagraph = currentMatch.paragraph
            jump = currentMatch.paragraph
        }
    }

    private func navigateMatch(forward: Bool) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + (forward ? 1 : matches.count - 1)) % matches.count
        if let currentMatch {
            isFollowing = false
            jump = currentMatch.paragraph
            activeParagraph = currentMatch.paragraph
        }
    }

    private func navigateReview(forward: Bool) {
        let indices = entry.reviewParagraphs.sorted()
        let next =
            forward
            ? indices.first { $0 > (activeParagraph ?? -1) } ?? indices.first
            : indices.last { $0 < (activeParagraph ?? entry.paragraphs.count) } ?? indices.last
        guard let next else { return }
        isFollowing = false
        activeParagraph = next
        jump = next
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                Text("Audio").font(.callout.weight(.medium))
                if !entry.paragraphs.isEmpty {
                    replayPassage
                    paragraphStep(by: -1)
                    paragraphStep(by: 1)
                }
                Spacer(minLength: 12)
                if !entry.paragraphs.isEmpty {
                    if isFollowSuspended {
                        Button("Return to playback", systemImage: "arrow.uturn.backward") {
                            isFollowing = true
                            isFollowSuspended = false
                        }
                        .disabled(!model.player.isOpen)
                    } else {
                        Toggle("Follow playback", isOn: $isFollowing)
                            .toggleStyle(.checkbox)
                            .font(.callout)
                            .help("Scroll to the paragraph being played")
                    }
                }
            }
            PlayerBar(
                player: model.player,
                marks: entry.paragraphs.map(\.seconds),
                highlighted: focused,
                length: entry.duration ?? 0,
                play: { model.replay(entry.id, from: $0, leadIn: 0) },
                hover: { focused = $0 },
                jump: { jump = $0 })
        }
    }

    /// What is happening to this transcript. The work in progress is read from
    /// the model rather than the entry. Repairing the repeats of a finished
    /// transcript leaves it finished throughout, since its text stays complete.
    @ViewBuilder
    private var state: some View {
        if isRunning {
            progress
        } else {
            switch entry.state {
            case .waiting, .running:
                waiting
            case .finished:
                EmptyView()
            case .stopped:
                HStack(spacing: 12) {
                    Label("Stopped before the end", systemImage: "stop.circle")
                        .foregroundStyle(.orange)
                    retry
                }
            case .failed(let message):
                HStack(spacing: 12) {
                    Label(message, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    retry
                }
            }
        }
    }

    /// A retry repeats the job this recording was given, not the settings that
    /// happen to be on the New Transcription page now.
    private var retry: some View {
        Button("Retry") { model.retry(entry.id) }
            .help("Transcribe the recording again with the settings it was given")
    }

    /// Waiting for its turn, or for the model it needs. A transfer that was
    /// cancelled or failed leaves the recording here instead of marking it
    /// failed, since only the model is missing, not the recording.
    @ViewBuilder
    private var waiting: some View {
        if case .downloading(let fraction) = model.stage,
            model.downloadingModel?.id == entry.modelFile
        {
            HStack(spacing: 12) {
                running("Downloading the model", fraction)
                Button("Cancel") { model.cancel() }
                Spacer()
            }
            .frame(height: 34)
        } else if model.canStart {
            HStack(spacing: 12) {
                Button(model.isScheduled(entry.id) ? "Continue Transcription" : "Review Settings") {
                    if model.isScheduled(entry.id) {
                        model.continueQueue()
                    } else {
                        model.pane = .new
                    }
                }
                .buttonStyle(.borderedProminent)
                Text(startingNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Waiting for its turn")
                .foregroundStyle(.secondary)
        }
    }

    private var startingNote: LocalizedStringKey {
        if let wanted = model.missingModel {
            return "\(wanted.name) is downloaded first."
        }
        let waiting = model.waiting.count
        return waiting > 1
            ? "Transcribes the \(waiting) recordings waiting, in turn."
            : "One recording at a time, in the order you added them."
    }

    /// One shape for every step of the job, so the page reads the same way
    /// whichever step is under way.
    private var progress: some View {
        HStack(spacing: 12) {
            switch model.stage {
            case .decoding:
                running("Converting the audio", nil)
            case .loading:
                running("Loading the model", nil)
            case .transcribing(let fraction):
                running("Transcribing", fraction)
                Button("Pause") { model.pause() }
            case .repairing(let fraction):
                running("Transcribing the repeats", fraction)
            case .paused(let fraction):
                Text("Paused")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ProgressView(value: fraction)
                    .frame(minWidth: 60, maxWidth: 180)
                Text(percent(fraction))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Resume") { model.resume() }
            case .stopping:
                Text("Stopping")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            case .waiting, .downloading:
                EmptyView()
            }
            if model.stage != .stopping {
                Button("Cancel") { model.cancel() }
            }
            Spacer()
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private func running(_ title: LocalizedStringKey, _ fraction: Double?) -> some View {
        Text(title)
            .font(.headline)
        if let fraction {
            ProgressView(value: fraction)
                .frame(minWidth: 60, maxWidth: 180)
            Text(percent(fraction))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    /// Exporting, and everything else a finished transcript can be put
    /// through. The first export asks where to put the file, as any Mac
    /// application does; an update writes over what it wrote before.
    @ViewBuilder
    private var actions: some View {
        if !isRunning && !entry.paragraphs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            entry.subtitles && entry.timesSentences
                                ? "Export text and original subtitles" : "Export text"
                        )
                        .font(.callout.weight(.medium))
                        exported
                    }
                    Spacer(minLength: 8)
                    Button {
                        showingExportOptions = true
                    } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 16, height: 16)
                    }
                    .accessibilityLabel("Export options")
                    .help("Export options")
                    .popover(isPresented: $showingExportOptions) {
                        EntryExportOptions(
                            entry: entry, isRunning: isRunning, engine: engine,
                            setSubtitles: { model.setSubtitles($0, for: entry.id) },
                            setTextLayout: { model.setTextLayout($0, for: entry.id) },
                            setRemovesHesitations: {
                                model.setRemovesHesitations($0, for: entry.id)
                            })
                    }
                    export
                }
            }
        }
    }

    /// One button, whose meaning follows the file rather than the saved
    /// record, so a user whose export was deleted or moved is never left
    /// pressing a button that does nothing.
    @ViewBuilder
    private var export: some View {
        switch model.exportState(of: entry) {
        case .none, .missing:
            Button("Export Text As…") { exportAs() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command, .shift])
        case .outOfDate:
            Button("Update Export") { model.updateExport(entry.id) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
        case .current:
            Button("Update Export") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }

    @ViewBuilder
    private var exported: some View {
        switch model.exportState(of: entry) {
        case .none:
            Text("Create a separate file to share or keep.")
                .font(.caption).foregroundStyle(.secondary)
        case .missing:
            Text("The previous export was moved or deleted.")
                .font(.caption).foregroundStyle(.secondary)
        case .current, .outOfDate:
            if let first = entry.saved.first {
                Text(
                    model.exportState(of: entry) == .outOfDate
                        ? "Export needs updating: \(first.lastPathComponent)"
                        : "Export is up to date: \(first.lastPathComponent)"
                )
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// The save panel every Mac application uses, so the user chooses the name
    /// and the place, and macOS is what asks before replacing a file.
    private func exportAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Transcript.suggestedName(
            for: entry.name, partial: entry.isPartial)
        panel.allowedContentTypes =
            entry.textLayout == .markdown
            ? [UTType(filenameExtension: "md") ?? .plainText] : [.plainText]
        panel.directoryURL = entry.location.deletingLastPathComponent()
        panel.canCreateDirectories = true
        if entry.subtitles && entry.timesSentences {
            panel.message = String(
                localized: "The subtitles are written beside the text, under the same name.")
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.export(entry.id, to: destination)
    }
}

/// Formats a duration for display, such as recording length or time spent transcribing.
func formattedDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
}
