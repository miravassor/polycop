// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The export, a section of the inspector: the format and its choices on rows,
/// then one button. Each export is a new file, made where the user chooses, as
/// a copy to share or keep; the corrections themselves live in the library.
struct EntryExportSection: View {
    let model: AppModel
    let facts: Facts

    /// What the export section shows of the transcript, which a correction
    /// typed in the text leaves as it is.
    struct Facts: Equatable {
        var id: Entry.ID
        var canExport: Bool
        var exportFormat: Transcript.Format
        var exportsTimes: Bool
        var formats: [Transcript.Format]
        var coversHesitations: Bool
        var removesHesitations: Bool
        var lastExport: URL?
    }

    var body: some View {
        if facts.canExport {
            FoldingSection(.export, reading: model.reading) {
                Picker(
                    "Format",
                    selection: Binding(
                        get: { facts.exportFormat },
                        set: { model.setExport($0, times: facts.exportsTimes, for: facts.id) })
                ) {
                    ForEach(facts.formats, id: \.self) {
                        Text(Self.title(of: $0)).tag($0)
                    }
                }
                // Subtitles keep the model's words and timings, as they are.
                if facts.exportFormat != .subtitles {
                    Toggle(
                        "Timecodes",
                        isOn: Binding(
                            get: { facts.exportsTimes },
                            set: { model.setExport(facts.exportFormat, times: $0, for: facts.id) })
                    )
                    .help("Write each paragraph's time before it")
                    // Said under its name, as in Settings: what it removes
                    // is not obvious.
                    if facts.coversHesitations {
                        Toggle(
                            isOn: Binding(
                                get: { facts.removesHesitations },
                                set: { model.setRemovesHesitations($0, for: facts.id) })
                        ) {
                            Text("Remove filler words")
                            Text("Euh, hum and the like.")
                        }
                    }
                }
                lastExport
                Button {
                    if let entry = model.entry(facts.id) {
                        Self.exportAs(entry, with: model)
                    }
                } label: {
                    Text("Export…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Make a new file (Command-S)")
            } footer: {
                // Only what a student could not guess: that subtitles leave
                // the corrections out.
                if facts.exportFormat == .subtitles {
                    Text(
                        "Subtitles keep the model's words and timings; corrections go into the text formats."
                    )
                }
            }
        }
    }

    @ViewBuilder private var lastExport: some View {
        if let file = facts.lastExport {
            LabeledContent {
                Button("Show in Finder") {
                    if let entry = model.entry(facts.id) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            model.existingExports(of: entry))
                    }
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
    /// format and its choices are set before, in the inspector; the name shows
    /// the extension they give.
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

extension EntryExportSection.Facts {
    init(entry: Entry, isRunning: Bool, lastExport: URL?) {
        self.init(
            id: entry.id,
            canExport: !isRunning && !entry.paragraphs.isEmpty,
            exportFormat: entry.exportFormat,
            exportsTimes: entry.exportsTimes,
            formats: EntryExportSection.formats(for: entry),
            coversHesitations: Hesitations.cover(entry),
            removesHesitations: entry.removesHesitations ?? false,
            lastExport: lastExport)
    }
}
