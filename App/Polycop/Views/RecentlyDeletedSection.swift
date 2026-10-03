// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Removed transcripts, kept for a while as Notes and Voice Memos keep them.
/// Shown only when there is one. A row is not a page: it is recovered or
/// deleted from its menu.
struct RecentlyDeletedSection: View {
    let model: AppModel
    @State private var deleting: Entry?

    var body: some View {
        if !model.recentlyDeleted.isEmpty {
            Section {
                ForEach(model.recentlyDeleted) { entry in
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5)
                        .contextMenu {
                            Button("Recover") { model.recoverEntry(entry.id) }
                            Button("Delete Immediately…", role: .destructive) { deleting = entry }
                        }
                }
            } header: {
                Text("Recently Deleted")
            } footer: {
                Text(
                    "Transcripts are deleted for good after 30 days. Audio files and exports are kept."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .confirmationDialog(
                "Delete this transcript immediately?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    if let deleting { model.deleteEntry(deleting.id) }
                    deleting = nil
                }
            } message: {
                Text(
                    "The transcript and its corrections will be deleted. You can't undo this action."
                )
            }
        }
    }
}
