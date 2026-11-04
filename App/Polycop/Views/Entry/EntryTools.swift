// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The page's tools in the window's toolbar, each also reachable by its
/// shortcut; the actions on the whole transcript in its More menu.
///
/// They are given what they show rather than the transcript: SwiftUI redraws
/// a view whose inputs change, and AppKit then rebuilds the toolbar's items
/// and menus, which with the transcript would happen at every correction.
/// Their actions read the transcript from the model when chosen.
struct EntryTools: View {
    let model: AppModel
    let id: Entry.ID
    let facts: Facts
    let page: PageNavigation
    @Binding var isComparing: Bool
    @Binding var isFindShown: Bool
    @Binding var isReplacing: Bool
    var isSearchFocused: FocusState<Bool>.Binding
    @Binding var showsUncertainWords: Bool
    @Binding var size: Double
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
        var hasExport: Bool
        var isRunning: Bool

        var hasText: Bool { paragraphCount > 0 }
    }

    var body: some View {
        // One capsule of evenly spaced symbols: the menus show no arrow,
        // which would set one apart in a capsule of its own.
        if facts.hasText {
            compareToggle
            reviewMenu
            findButton
            textMenu
        }
        EntryActionsMenu(
            model: model, id: id, facts: facts,
            confirmingRevert: $confirmingRevert, confirmingRemoval: $confirmingRemoval)
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
                .disabled(facts.flagged.isEmpty)
            Button("Next Flagged Passage") { navigateReview(forward: true) }
                .disabled(facts.flagged.isEmpty)
            Divider()
            Text("Use the flag beside a paragraph to review it later.")
        } label: {
            Label("Review (\(facts.flagged.count))", systemImage: "flag")
        }
        .menuIndicator(.hidden)
        .help("Flagged passages: \(facts.flagged.count)")
    }

    /// Pressed while the find bar shows, so a second click closes it; Command-F,
    /// in the Text menu, only ever opens it.
    private var findButton: some View {
        Toggle(isOn: $isFindShown) {
            Label("Find", systemImage: "magnifyingglass")
        }
        .help(isFindShown ? "Close the find bar" : "Find in your text (Command-F)")
    }

    private var textMenu: some View {
        Menu {
            Button("Undo Last Correction") { model.undo(id) }
                .disabled(facts.isRunning || !facts.canUndo)
            Button("Find") {
                isFindShown = true
                isSearchFocused.wrappedValue = true
            }
            .keyboardShortcut("f")
            Button("Find and Replace") {
                isFindShown = true
                isReplacing = true
                isSearchFocused.wrappedValue = true
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

    private func navigateReview(forward: Bool) {
        let next =
            forward
            ? facts.flagged.first { $0 > (page.activeParagraph ?? -1) } ?? facts.flagged.first
            : facts.flagged.last { $0 < (page.activeParagraph ?? facts.paragraphCount) }
                ?? facts.flagged.last
        guard let next else { return }
        page.show(next)
    }
}
