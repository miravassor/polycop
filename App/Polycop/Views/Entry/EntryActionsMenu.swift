// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                Button("Export Text…", action: exportAs)
                    .disabled(isRunning)
                let exports = entry.saved.filter {
                    FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
                }
                if !exports.isEmpty {
                    Button("Show Export in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(exports)
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
