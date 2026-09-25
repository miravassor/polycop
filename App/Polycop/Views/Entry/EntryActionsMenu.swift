// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The overflow menu for one transcript: corrections, export and removal.
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
                Button("Export Text As…", action: exportAs)
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
            Image(systemName: "ellipsis").frame(width: 16, height: 16)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 28)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Transcript actions")
        .help("Transcript actions")
    }
}
