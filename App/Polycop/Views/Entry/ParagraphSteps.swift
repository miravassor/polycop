// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Moving through a transcript while listening: replaying the active
/// paragraph, playing the one before or after, or taking the page back to what
/// plays. The player, the page and the Playback menu share it.
struct ParagraphSteps {
    /// What the Playback menu and step helpers read of the transcript, which a
    /// correction typed in the text leaves as it is.
    struct Facts: Equatable {
        var id: Entry.ID
        var hasText: Bool
        var hasRecording: Bool
        /// Whether any word has a time, which the highlight and the cursor need.
        var hasTimedWords: Bool
    }

    let model: AppModel
    let facts: Facts
    let state: PageNavigationState

    var isFollowSuspended: Bool { state.isFollowSuspended }
    var canReplay: Bool { state.hasActiveParagraph && facts.hasRecording }
    var canStop: Bool { model.player.isOpen || model.player.isPreparing }

    /// Stops and closes the recording.
    func stop() { model.player.stop() }
    var canStep: Bool { facts.hasRecording && facts.hasText }

    /// Whether the text is there but no word has a time, which Follow's choice says.
    var lacksTimedWords: Bool { facts.hasText && !facts.hasTimedWords }

    /// Follows playback again after the reader looked elsewhere, with the
    /// paragraph playing at the top even if it was in view.
    func returnToPlayback() {
        guard let entry = model.entry(facts.id) else { return }
        state.isFollowSuspended = false
        state.showAtTop = TranscriptNavigation.paragraph(
            returningTo: model.player.position, starts: entry.paragraphs.map(\.seconds))
    }

    /// Replays the active paragraph with two seconds of context.
    func replay() {
        guard let activeParagraph = state.activeParagraph, let entry = model.entry(facts.id),
            entry.paragraphs.indices.contains(activeParagraph)
        else { return }
        model.replay(
            entry.id, from: max(0, entry.paragraphs[activeParagraph].seconds - 2), leadIn: 0)
    }

    /// Plays the next or previous paragraph, counted from the one playing. A
    /// step back while one plays first goes to its start.
    func step(by offset: Int) {
        guard let entry = model.entry(facts.id) else { return }
        let starts = entry.paragraphs.map(\.seconds)
        let player = model.player
        let next =
            if offset < 0, player.isOpen {
                TranscriptNavigation.paragraph(steppingBackAt: player.position, starts: starts)
            } else {
                TranscriptNavigation.paragraph(
                    from: player.isOpen
                        ? TranscriptNavigation.paragraph(playingAt: player.position, starts: starts)
                        : state.activeParagraph,
                    offset: offset, count: starts.count)
            }
        guard let next else { return }
        state.activeParagraph = next
        state.jump = next
        model.replay(entry.id, from: starts[next])
    }
}

extension ParagraphSteps.Facts {
    init(entry: Entry, hasRecording: Bool, hasTimedWords: Bool) {
        self.init(
            id: entry.id,
            hasText: !entry.paragraphs.isEmpty,
            hasRecording: hasRecording,
            hasTimedWords: hasTimedWords)
    }
}

extension FocusedValues {
    /// The open transcript's steps, for the Playback menu.
    @Entry var paragraphSteps: ParagraphSteps?
}

/// The Playback menu: playing from the text cursor, replaying the active
/// paragraph, playing the one before or after, how the page follows, and
/// stopping.
struct PlaybackCommands: Commands {
    let reading: ReadingSettings
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
            Divider()
            FollowChoice(reading: reading, lacksTimedWords: steps?.lacksTimedWords == true)
                .disabled(steps?.facts.hasText != true)
            Button("Return to Playback") { steps?.returnToPlayback() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(steps?.isFollowSuspended != true)
            Divider()
            Button("Stop") { steps?.stop() }
                .disabled(steps?.canStop != true)
        }
    }
}
