// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Several transcripts selected: the window shows what they are and what
/// can be done to all of them, rather than one of them at random.
struct SelectionView: View {
    let model: AppModel
    /// What the sidebar has selected, ordered here so `ContentView` does not
    /// read the library.
    let selection: Set<AppModel.Pane>
    let move: ([Entry.ID]) -> Void
    let remove: ([Entry.ID]) -> Void
    let tag: ([Entry.ID]) -> Void

    /// The visible transcripts selected, in the order the sidebar shows them.
    private var selected: [Entry.ID] {
        model.visibleEntryOrder.filter { selection.contains(.entry($0)) }
    }

    var body: some View {
        let selected = self.selected
        let isAnyFiled = selected.contains { model.entry($0)?.folderID != nil }
        let areAllPinned =
            !selected.isEmpty && selected.allSatisfy { model.entry($0)?.isPinned == true }
        VStack(spacing: Spacing.block) {
            Text(
                "Shift or command click to change the selection. Drag them onto a folder to file them."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            WrappingLayout {
                Button("Move to Folder…") { move(selected) }
                    .disabled(model.foldersAreDamaged)
                Button("Remove from Folder") {
                    model.moveEntries(selected, to: nil)
                }
                .disabled(model.foldersAreDamaged || !isAnyFiled)
                Button(areAllPinned ? "Unpin" : "Pin") {
                    model.setPinned(selected, to: !areAllPinned)
                }
                TranscriptFlairMenu(model: model, targets: selected) { tag(selected) }
                Button("Remove from Library…", role: .destructive) { remove(selected) }
            }
            if let failure = model.failure {
                Notice(failure, .failure)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity)
        .navigationTitle("\(selected.count) Transcripts Selected")
        .focusedSceneValue(\.selectedTranscripts, selected)
    }
}
