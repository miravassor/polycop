// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Files the transcripts chosen into a folder, or out of any.
struct MoveTranscriptsSheet: View {
    let model: AppModel
    @Binding var moving: [Entry.ID]
    @Binding var destinationFolder: UUID?
    /// Called with the folder they went into, so the sidebar can open it.
    let opened: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(moving.count > 1 ? "Move transcripts" : "Move transcript")
                .font(.title2.weight(.semibold))
            Text(
                moving.count > 1
                    ? "\(moving.count) transcripts"
                    : (moving.first.flatMap { model.entry($0)?.name } ?? "")
            )
            .lineLimit(2)
            .truncationMode(.middle)
            Picker("Folder", selection: $destinationFolder) {
                Text("Unfiled").tag(UUID?.none)
                ForEach(model.folders) { folder in
                    Text(folder.name).tag(UUID?.some(folder.id))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { moving = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Move") {
                    for id in moving { model.moveEntry(id, to: destinationFolder) }
                    if let destinationFolder { opened(destinationFolder) }
                    moving = []
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
