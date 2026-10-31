// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Moving through a transcript while listening: replaying the active
/// paragraph, or playing the one before or after. The inspector's buttons and
/// the Playback menu share it, so the shortcuts work with the inspector hidden.
struct ParagraphSteps {
    let model: AppModel
    let entry: Entry
    @Binding var activeParagraph: Int?
    @Binding var jump: Int?

    var canReplay: Bool { activeParagraph != nil && entry.hasRecording }
    var canStep: Bool { entry.hasRecording && !entry.paragraphs.isEmpty }

    /// Replays the active paragraph with two seconds of context.
    func replay() {
        guard let activeParagraph, entry.paragraphs.indices.contains(activeParagraph) else {
            return
        }
        model.replay(
            entry.id, from: max(0, entry.paragraphs[activeParagraph].seconds - 2), leadIn: 0)
    }

    /// Plays the next or previous paragraph, counted from the one playing.
    func step(by offset: Int) {
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
    }
}

extension FocusedValues {
    /// The open transcript's steps, for the Playback menu.
    @Entry var paragraphSteps: ParagraphSteps?
}

/// The Playback menu: playing from the text cursor, replaying the active
/// paragraph and playing the one before or after.
struct PlaybackCommands: Commands {
    @FocusedValue(\.paragraphSteps) private var steps

    var body: some Commands {
        CommandMenu("Playback") {
            // Only the paragraph being edited knows where its words are.
            Button("Play From Cursor") {
                let action = #selector(WordTextView.playFromCursor(_:))
                if !NSApp.sendAction(action, to: nil, from: nil) { NSSound.beep() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Replay Passage") { steps?.replay() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(steps?.canReplay != true)
            Button("Previous Paragraph") { steps?.step(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(steps?.canStep != true)
            Button("Next Paragraph") { steps?.step(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(steps?.canStep != true)
        }
    }
}
