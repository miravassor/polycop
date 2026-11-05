// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The More menu of a transcript's toolbar: corrections, export and removal.
/// Given what it shows rather than the transcript, as `EntryTools` says.
struct EntryActionsMenu: View {
    let model: AppModel
    let id: Entry.ID
    let facts: EntryTools.Facts
    @Binding var confirmingRevert: Bool
    @Binding var confirmingRemoval: Bool

    var body: some View {
        Menu {
            if facts.hasText {
                Button("Undo Last Correction") { model.undo(id) }
                    .disabled(facts.isRunning || !facts.canUndo)
                Button("Revert to Original…") { confirmingRevert = true }
                    .disabled(facts.isRunning || !facts.isEdited)
                Button("Duplicate Transcript") { model.duplicate(id) }
                    .disabled(facts.isRunning)
                Divider()
                Button("Export…") {
                    guard let entry = model.entry(id) else { return }
                    EntryExportSection.exportAs(entry, with: model)
                }
                .disabled(facts.isRunning)
                if facts.hasExport {
                    Button("Show Export in Finder") {
                        guard let entry = model.entry(id) else { return }
                        NSWorkspace.shared.activateFileViewerSelecting(
                            model.existingExports(of: entry))
                    }
                }
                Button("Transcribe Again with Current Settings…") {
                    model.transcribeAgain(id)
                }
                .disabled(facts.isRunning || !facts.hasRecording)
                Divider()
            }
            Button("Remove from Library…", role: .destructive) { confirmingRemoval = true }
                .disabled(facts.isRunning)
        } label: {
            Label("Transcript Actions", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help("Transcript actions")
    }
}
