// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The page's tools in the window's toolbar, each also reachable by its
/// shortcut; the actions on the whole transcript in its More menu.
///
/// A redrawn tool makes AppKit rebuild its toolbar item and menu, so these must
/// not be redrawn when a correction changes only the text. The toolbar redoes
/// this view at each update of the page whatever it is given, so every tool is
/// a view of its own, given what it shows rather than the transcript. Actions
/// read the transcript from the model when chosen.
struct EntryTools: View {
    let model: AppModel
    let id: Entry.ID
    let facts: Facts
    let page: PageNavigation
    @Binding var find: TranscriptFind
    var isSearchFocused: FocusState<Bool>.Binding
    @Binding var confirmingRevert: Bool
    @Binding var confirmingRemoval: Bool

    /// What the tools show of the transcript, which a correction typed in the
    /// text leaves as it is.
    struct Facts: Equatable {
        var paragraphCount: Int
        /// The flagged paragraphs, in order.
        var flagged: [Int]
        var canUndo: Bool
        var isEdited: Bool
        var hasRecording: Bool
        /// Whether any word has a time, which the cursor needs to follow.
        var hasTimedWords: Bool
        var hasExport: Bool
        var isRunning: Bool

        var hasText: Bool { paragraphCount > 0 }
    }

    var body: some View {
        // One capsule of evenly spaced symbols: the menus show no arrow,
        // which would set one apart in a capsule of its own.
        if facts.hasText {
            CompareToggle(reading: model.reading)
            ReviewMenu(facts: facts, page: page)
            FindToggle(find: $find)
            TextMenu(
                model: model, id: id, facts: facts, find: $find, isSearchFocused: isSearchFocused)
        }
        EntryActionsMenu(
            model: model, id: id, facts: facts,
            confirmingRevert: $confirmingRevert, confirmingRemoval: $confirmingRemoval)
    }
}

/// One switch rather than two choices: the original beside the text, or not.
private struct CompareToggle: View {
    @Bindable var reading: ReadingSettings

    var body: some View {
        Toggle(isOn: $reading.isComparing) {
            Label("Compare", systemImage: "rectangle.split.2x1")
        }
        .help(reading.isComparing ? "Show your text alone" : "Show the original beside your text")
    }
}

/// Moving between the passages flagged for review.
private struct ReviewMenu: View {
    let facts: EntryTools.Facts
    let page: PageNavigation

    var body: some View {
        Menu {
            Button("Previous Flagged Passage") { step(forward: false) }
                .disabled(facts.flagged.isEmpty)
            Button("Next Flagged Passage") { step(forward: true) }
                .disabled(facts.flagged.isEmpty)
            Divider()
            Text("Use the flag beside a paragraph to review it later.")
        } label: {
            Label("Review (\(facts.flagged.count))", systemImage: "flag")
        }
        .menuIndicator(.hidden)
        .help("Flagged passages: \(facts.flagged.count)")
    }

    private func step(forward: Bool) {
        let next =
            forward
            ? facts.flagged.first { $0 > (page.activeParagraph ?? -1) } ?? facts.flagged.first
            : facts.flagged.last { $0 < (page.activeParagraph ?? facts.paragraphCount) }
                ?? facts.flagged.last
        guard let next else { return }
        page.show(next)
    }
}

/// Pressed while the find bar shows, so a second click closes it; Command-F,
/// in the Text menu, only ever opens it.
private struct FindToggle: View {
    @Binding var find: TranscriptFind

    var body: some View {
        Toggle(isOn: $find.isShown) {
            Label("Find", systemImage: "magnifyingglass")
        }
        .help(find.isShown ? "Close the find bar" : "Find in your text (Command-F)")
    }
}

/// Finding, the text's size, following and the last correction.
private struct TextMenu: View {
    let model: AppModel
    let id: Entry.ID
    let facts: EntryTools.Facts
    @Binding var find: TranscriptFind
    var isSearchFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var reading = model.reading
        Menu {
            Button("Undo Last Correction") { model.undo(id) }
                .disabled(facts.isRunning || !facts.canUndo)
            Button("Find") {
                find.isShown = true
                isSearchFocused.wrappedValue = true
            }
            .keyboardShortcut("f")
            Button("Find and Replace") {
                find.isShown = true
                find.isReplacing = true
                isSearchFocused.wrappedValue = true
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Toggle("Underline Uncertain Words", isOn: $reading.showsUncertainWords)
            Divider()
            Button("Smaller Text") { reading.textSize = max(10, reading.textSize - 1) }
                .keyboardShortcut("-")
                .disabled(reading.textSize <= 10)
            Button("Larger Text") { reading.textSize = min(28, reading.textSize + 1) }
                .keyboardShortcut("+")
                .disabled(reading.textSize >= 28)
            Divider()
            FollowChoice(reading: reading, hasTimedWords: facts.hasTimedWords)
        } label: {
            Label("Text", systemImage: "textformat.size")
        }
        .menuIndicator(.hidden)
        .help("Text size, following and correction history")
    }
}
