// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The More menu of a transcript's toolbar: corrections, export and removal.
struct EntryActionsMenu: View {
    let model: AppModel
    let entry: Entry
    let isRunning: Bool
    @Binding var confirmingRevert: Bool
    @Binding var confirmingRemoval: Bool
    let exportAs: () -> Void

    var body: some View {
        Menu {
            if !entry.paragraphs.isEmpty {
                Button("Undo Last Correction") { model.undo(entry.id) }
                    .disabled(isRunning || !model.canUndo(entry.id))
                Button("Revert to Original…") { confirmingRevert = true }
                    .disabled(isRunning || !entry.isEdited)
                Button("Duplicate Transcript") { model.duplicate(entry.id) }
                    .disabled(isRunning)
                Divider()
                Button("Export…", action: exportAs)
                    .disabled(isRunning)
                if model.lastExport(of: entry) != nil {
                    Button("Show Export in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            model.existingExports(of: entry))
                    }
                }
                Button("Transcribe Again with Current Settings…") {
                    model.transcribeAgain(entry.id)
                }
                .disabled(isRunning || !entry.hasRecording)
                Divider()
            }
            Button("Remove from Library…", role: .destructive) { confirmingRemoval = true }
                .disabled(isRunning)
        } label: {
            Label("Transcript Actions", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help("Transcript actions")
    }
}
