// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Several transcripts selected: the window shows what they are and what
/// can be done to all of them, rather than one of them at random.
struct SelectionView: View {
    let model: AppModel
    /// The transcripts selected, in the order the list shows them.
    let selected: [Entry.ID]
    let move: ([Entry.ID]) -> Void
    let remove: ([Entry.ID]) -> Void
    let tag: ([Entry.ID]) -> Void

    /// Whether any of them is in a folder, to be taken out of it.
    private var isAnyFiled: Bool {
        selected.contains { model.entry($0)?.folderID != nil }
    }

    private var areAllPinned: Bool {
        !selected.isEmpty && selected.allSatisfy { model.entry($0)?.isPinned == true }
    }

    var body: some View {
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
    }
}
