// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The recording under the transcript: replaying the active passage, stepping
/// from paragraph to paragraph, following playback, and the player itself.
struct EntryAudio: View {
    let model: AppModel
    let entry: Entry
    @Binding var focused: Int?
    @Binding var activeParagraph: Int?
    @Binding var jump: Int?
    @Binding var isFollowing: Bool
    @Binding var isFollowSuspended: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Audio").font(.headline)
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
                resume: entry.playbackPosition ?? 0,
                play: { model.replay(entry.id, from: $0, leadIn: 0) },
                hover: { focused = $0 },
                jump: { jump = $0 })
        }
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
