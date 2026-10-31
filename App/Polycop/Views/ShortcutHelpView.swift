// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ShortcutHelpView: View {
    var body: some View {
        Form {
            Section("Playback and correction") {
                shortcut("Play or pause, outside the text", "Space")
                shortcut("Play or pause, anywhere", "⇧⌘Space")
                shortcut("Play or pause, on the video", "Click")
                shortcut("Fill the screen with the video, or leave it", "Double-click")
                shortcut("Show or hide the library", "⌃⌘S")
                shortcut("Show or hide the inspector", "⌃⌘I")
                shortcut("Leave the text", "Esc")
                shortcut("Replay active paragraph", "⌥⌘R")
                shortcut("Play next paragraph", "⌥⌘↓")
                shortcut("Play previous paragraph", "⌥⌘↑")
                shortcut("Play from a word", "⌥ Click")
                shortcut("Play from the text cursor", "⌥⌘P")
                shortcut("Undo typing in the active paragraph", "⌘Z")
                shortcut("Smaller text", "⌘−")
                shortcut("Larger text", "⌘+")
                Text(
                    "Replay starts two seconds before the active paragraph. Playing from a word or the cursor needs a transcript timed word by word. While you edit, Space types a space and the other shortcuts keep working; Esc leaves the text."
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
                shortcut("Export the text to a new file", "⌘S")
                Text(
                    "Corrections are saved in the library automatically. An export is a separate file to share or keep, made anew each time."
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
