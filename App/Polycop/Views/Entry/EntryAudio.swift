// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The recording in the inspector: its picture for a video, replaying the
/// active passage, stepping from paragraph to paragraph and following
/// playback. The player itself stays under the text, inspector or not.
struct EntryAudio: View {
    let model: AppModel
    let entry: Entry
    @Binding var activeParagraph: Int?
    @Binding var jump: Int?
    @Binding var following: Following
    @Binding var isFollowSuspended: Bool
    /// Whether any word has a time, which the highlight and the cursor need.
    let hasTimedWords: Bool
    /// The size of the recording's picture, nil for sound alone.
    @State private var picture: CGSize?
    /// Where the recording is, found once rather than at each redraw.
    @State private var source: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let picture, let source {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Video").font(.headline)
                        Spacer(minLength: 8)
                        VideoControls(model: model)
                    }
                    EntryVideo(
                        model: model, id: entry.id, source: source, picture: picture,
                        resume: entry.playbackPosition ?? 0)
                }
            }
            if !entry.paragraphs.isEmpty {
                if picture != nil { Divider() }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Playback").font(.headline)
                    HStack(spacing: 12) {
                        replayPassage
                        ControlGroup {
                            paragraphStep(by: -1)
                            paragraphStep(by: 1)
                        }
                        .fixedSize()
                    }
                    followControl
                }
            }
        }
        .task(id: entry.recording) {
            let recording = model.recording(of: entry)
            source = recording
            picture = await Player.pictureSize(of: recording)
            // The picture shows where the reader left off, before playing.
            if picture != nil { model.player.prepare(recording, at: entry.playbackPosition ?? 0) }
        }
    }

    @ViewBuilder private var followControl: some View {
        if isFollowSuspended {
            Button("Return to playback", systemImage: "arrow.uturn.backward") {
                isFollowSuspended = false
            }
            .disabled(!model.player.isOpen)
        } else {
            followPicker
        }
    }

    private var followPicker: some View {
        Picker("Follow", selection: $following) {
            ForEach(Following.allCases, id: \.self) { choice in
                Text(choice.name)
                    .tag(choice)
                    .selectionDisabled(choice == .cursor && !hasTimedWords)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .font(.callout)
        .help(
            hasTimedWords
                ? "Page scrolls to the paragraph being played. Page and Cursor also takes the text cursor along with the word heard."
                : "Page scrolls to the paragraph being played. This transcript has no word timings, so the word heard is not highlighted and the cursor cannot follow it."
        )
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
            Label(
                offset < 0 ? "Previous" : "Next",
                systemImage: offset < 0 ? "chevron.up" : "chevron.down"
            )
            .labelStyle(.titleAndIcon)
        }
        .keyboardShortcut(offset < 0 ? .upArrow : .downArrow, modifiers: [.command, .option])
        .disabled(!entry.hasRecording)
        .help(offset < 0 ? "Play the previous paragraph" : "Play the next paragraph")
        .accessibilityLabel(offset < 0 ? "Play the previous paragraph" : "Play the next paragraph")
    }
}
