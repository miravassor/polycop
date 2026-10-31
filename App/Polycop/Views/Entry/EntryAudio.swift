// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The recording beside the transcript: its picture for a video, replaying
/// the active passage, stepping from paragraph to paragraph, following
/// playback, and the player itself.
struct EntryAudio: View {
    let model: AppModel
    let entry: Entry
    @Binding var focused: Int?
    @Binding var activeParagraph: Int?
    @Binding var jump: Int?
    @Binding var following: Following
    @Binding var isFollowSuspended: Bool
    /// Whether any word has a time, which the highlight and the cursor need.
    let hasTimedWords: Bool
    /// Whether it sits in the column beside the transcript, too narrow for
    /// its controls on one line.
    let isBeside: Bool
    /// The tallest the picture may be. With less than a picture can use, it
    /// shrinks to a thumbnail beside the player bar, so the text keeps its room.
    let pictureRoom: CGFloat
    /// The size of the recording's picture, nil for sound alone.
    @State private var picture: CGSize?
    /// Where the recording is, found once rather than at each redraw.
    @State private var source: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Told rather than measured: measuring both layouts at each
            // correction handed over costs more than the page can spare.
            if isBeside {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        title
                        stepping
                    }
                    followControl
                }
            } else {
                HStack(spacing: 12) {
                    title
                    stepping
                    Spacer(minLength: 12)
                    followControl
                }
            }
            if let picture, let source {
                if pictureRoom < EntryVideo.smallest {
                    HStack(spacing: 12) {
                        video(source, picture, isThumbnail: true)
                        playerBar
                    }
                } else {
                    video(source, picture, isThumbnail: false)
                    playerBar
                }
            } else {
                playerBar
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

    private func video(_ source: URL, _ picture: CGSize, isThumbnail: Bool) -> some View {
        EntryVideo(
            model: model, id: entry.id, source: source, picture: picture,
            resume: entry.playbackPosition ?? 0,
            maxHeight: isThumbnail ? EntryVideo.thumbnailHeight : pictureRoom,
            isThumbnail: isThumbnail)
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

    private var title: some View {
        HStack(spacing: 8) {
            if picture == nil {
                Text("Audio").font(.headline)
            } else {
                Text("Video").font(.headline)
                VideoToggle()
            }
        }
    }

    @ViewBuilder private var stepping: some View {
        if !entry.paragraphs.isEmpty {
            replayPassage
            paragraphStep(by: -1)
            paragraphStep(by: 1)
        }
    }

    @ViewBuilder private var followControl: some View {
        if !entry.paragraphs.isEmpty {
            if isFollowSuspended {
                Button("Return to playback", systemImage: "arrow.uturn.backward") {
                    isFollowSuspended = false
                }
                .disabled(!model.player.isOpen)
            } else {
                followPicker
            }
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
            Image(systemName: offset < 0 ? "chevron.up" : "chevron.down")
        }
        .keyboardShortcut(offset < 0 ? .upArrow : .downArrow, modifiers: [.command, .option])
        .disabled(!entry.hasRecording)
        .help(offset < 0 ? "Play the previous paragraph" : "Play the next paragraph")
        .accessibilityLabel(offset < 0 ? "Play the previous paragraph" : "Play the next paragraph")
    }
}
