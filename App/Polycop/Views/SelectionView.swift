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

    /// Whether any of them is in a folder, to be taken out of it.
    private var isAnyFiled: Bool {
        selected.contains { model.entry($0)?.folderID != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(selected.count) transcripts selected")
                .font(.title2.weight(.semibold))
            Text(
                "Shift or command click to change the selection. Drag them onto a folder to file them."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Move to Folder…") { move(selected) }
                    .disabled(model.foldersAreDamaged)
                Button("Remove from Folder") {
                    for id in selected { model.moveEntry(id, to: nil) }
                }
                .disabled(model.foldersAreDamaged || !isAnyFiled)
                Button("Remove from Library…", role: .destructive) { remove(selected) }
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .notice(.red)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
