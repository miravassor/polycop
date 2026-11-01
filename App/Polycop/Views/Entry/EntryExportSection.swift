// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The export, a section of the inspector: the format and its choices on rows,
/// then one button. Each export is a new file, made where the user chooses, as
/// a copy to share or keep; the corrections themselves live in the library.
struct EntryExportSection: View {
    let model: AppModel
    let entry: Entry
    let isRunning: Bool

    var body: some View {
        if !isRunning && !entry.paragraphs.isEmpty {
            Section {
                Picker(
                    "Format",
                    selection: Binding(
                        get: { entry.exportFormat },
                        set: { model.setExport($0, times: entry.exportsTimes, for: entry.id) })
                ) {
                    ForEach(Self.formats(for: entry), id: \.self) {
                        Text(Self.title(of: $0)).tag($0)
                    }
                }
                // Subtitles keep the model's words and timings, as they are.
                if entry.exportFormat != .subtitles {
                    Toggle(
                        "Timecodes",
                        isOn: Binding(
                            get: { entry.exportsTimes },
                            set: { model.setExport(entry.exportFormat, times: $0, for: entry.id) })
                    )
                    .help("Write each paragraph's time before it")
                    // Said under its name, as in Settings: what it removes
                    // is not obvious.
                    Toggle(
                        isOn: Binding(
                            get: { entry.removesHesitations ?? false },
                            set: { model.setRemovesHesitations($0, for: entry.id) })
                    ) {
                        Text("Remove filler words")
                        Text("Euh, hum and the like.")
                    }
                }
                lastExport
                Button {
                    Self.exportAs(entry, with: model)
                } label: {
                    Text("Export…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Make a new file (Command-S)")
            } header: {
                Text("Export")
            } footer: {
                // Only what a student could not guess: that subtitles leave
                // the corrections out.
                if entry.exportFormat == .subtitles {
                    Text(
                        "Subtitles keep the model's words and timings; corrections go into the text formats."
                    )
                }
            }
        }
    }

    @ViewBuilder private var lastExport: some View {
        if let file = model.lastExport(of: entry) {
            LabeledContent {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        entry.saved.filter {
                            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
                        })
                }
            } label: {
                Text("Last Export")
                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// The name of each format.
    static func title(of format: Transcript.Format) -> String {
        switch format {
        case .plainText: String(localized: "Plain Text")
        case .markdown: String(localized: "Markdown")
        case .word: String(localized: "Word Document")
        case .subtitles: String(localized: "Subtitles (SRT)")
        }
    }

    /// The subtitles only for a model that times its sentences.
    static func formats(for entry: Entry) -> [Transcript.Format] {
        Transcript.Format.allCases.filter { $0 != .subtitles || entry.timesSentences }
    }

    /// The save panel every Mac application uses, so the user chooses the name
    /// and the place, and macOS is what asks before replacing a file. The
    /// format and its choices are set before, in the inspector, as Pages sets
    /// them before its save panel; the name shows the extension they give.
    static func exportAs(_ entry: Entry, with model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Transcript.suggestedName(
            for: entry.name, of: entry.recording, partial: entry.isPartial)
        panel.allowedContentTypes =
            switch entry.exportFormat {
            case .markdown: [UTType(filenameExtension: "md") ?? .plainText]
            case .word: [UTType(filenameExtension: "docx") ?? .data]
            case .subtitles: [UTType(filenameExtension: "srt") ?? .plainText]
            case .plainText: [.plainText]
            }
        panel.directoryURL = entry.location.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.export(entry.id, to: destination)
    }
}
