// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ShortcutHelpView: View {
    var body: some View {
        Form {
            Section("Playback and correction") {
                shortcut("Play or pause", "⇧⌘Space")
                shortcut("Replay active paragraph", "⌥⌘R")
                shortcut("Undo typing in the active paragraph", "⌘Z")
                shortcut("Smaller text", "⌘−")
                shortcut("Larger text", "⌘+")
                Text(
                    "Replay starts two seconds before the active paragraph. Playback shortcuts work while you edit; Space remains available for typing."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Search in the current transcript") {
                shortcut("Find", "⌘F")
                shortcut("Find and replace", "⌥⌘F")
                shortcut("Next result", "⌘G")
                shortcut("Previous result", "⇧⌘G")
                Text("Result navigation is available while the search bar is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library") {
                shortcut("New transcription", "⌘N")
                shortcut("Add recordings", "⌘O")
                shortcut("Import transcript and audio", "⇧⌘O")
                shortcut("Start transcription", "⌘R")
                shortcut("New folder", "⇧⌘N")
                shortcut("Manage glossaries", "⌥⌘G")
            }
            Section("Export") {
                shortcut("First text export", "⇧⌘S")
                shortcut("Update an outdated export", "⌘S")
                Text(
                    "Corrections are saved in the library automatically. These shortcuts write a separate export file when the corresponding action is available."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Application") {
                shortcut("Settings", "⌘,")
                shortcut("Keyboard shortcuts", "⌥⌘/")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 570)
    }

    private func shortcut(_ title: LocalizedStringKey, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys).font(.body.monospaced()).foregroundStyle(.secondary)
        }
    }
}
