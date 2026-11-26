// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Files the transcripts chosen into a folder, or out of any.
struct MoveTranscriptsSheet: View {
    let model: AppModel
    @Binding var moving: [Entry.ID]
    @Binding var destinationFolder: UUID?
    /// Called with the destination folder (`nil` for Unfiled) so the sidebar can open it.
    let opened: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.block) {
            Text(moving.count > 1 ? "Move Transcripts" : "Move Transcript")
                .font(.sheetTitle)
            Text(
                moving.count > 1
                    ? "\(moving.count) transcripts"
                    : (moving.first.flatMap { model.entry($0)?.name } ?? "")
            )
            .lineLimit(2)
            .truncationMode(.middle)
            Picker("Folder", selection: $destinationFolder) {
                Text("Unfiled").tag(UUID?.none)
                ForEach(model.rootFolders) { folder in
                    Text(folder.name).tag(UUID?.some(folder.id))
                    ForEach(model.subfolders(of: folder.id)) { subfolder in
                        Text("\(folder.name) / \(subfolder.name)").tag(UUID?.some(subfolder.id))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { moving = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Move") {
                    model.moveEntries(moving, to: destinationFolder)
                    opened(destinationFolder)
                    moving = []
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.sheet)
        .frame(width: 380)
    }
}
