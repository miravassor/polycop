// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export choices, shown in a popover from the export options button.
struct EntryExportOptions: View {
    let entry: Entry
    let isRunning: Bool
    let engine: Engine?
    let setSubtitles: (Bool) -> Void
    let setTextLayout: (Transcript.TextLayout) -> Void
    let setRemovesHesitations: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export options").font(.headline)
            Picker(
                "Text",
                selection: Binding(
                    get: { entry.exportLayout }, set: { setTextLayout($0) })
            ) {
                ForEach(Transcript.TextLayout.allCases, id: \.self) {
                    Text(Self.title(of: $0)).tag($0)
                }
            }
            .disabled(isRunning)
            Toggle(
                "Leave out hesitations (euh, hum…)",
                isOn: Binding(
                    get: { entry.removesHesitations ?? false },
                    set: { setRemovesHesitations($0) })
            )
            .toggleStyle(.checkbox)
            .disabled(isRunning)
            Divider()
            if entry.timesSentences {
                Toggle(
                    "Include subtitles (SRT)",
                    isOn: Binding(get: { entry.subtitles }, set: { setSubtitles($0) })
                )
                .toggleStyle(.checkbox)
                .disabled(isRunning)
                Text(
                    "Corrections appear in the text export. Subtitles keep the original words and timings."
                )
                .font(.callout).foregroundStyle(.secondary)
            } else if let engine, let profile = engine.audioCpp {
                Text(
                    "\(engine.name) places timestamps every \(Int(profile.timestampSpacing)) seconds. Sentence-level subtitles are unavailable."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Text(
                "Export creates a separate file. Your corrections are saved automatically in the library."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340)
    }

    /// The name of each format, here and in the save panel.
    static func title(of layout: Transcript.TextLayout) -> String {
        switch layout {
        case .timestamped: String(localized: "With timestamps")
        case .plain: String(localized: "Without timestamps")
        case .markdown: String(localized: "Markdown")
        case .word: String(localized: "Word document")
        }
    }
}
