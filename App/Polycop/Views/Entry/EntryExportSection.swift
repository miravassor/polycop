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
                    Toggle(
                        "Leave out hesitations",
                        isOn: Binding(
                            get: { entry.removesHesitations ?? false },
                            set: { model.setRemovesHesitations($0, for: entry.id) })
                    )
                    .help("Leave out euh, hum and the like")
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
                Text(
                    entry.exportFormat == .subtitles
                        ? "Subtitles keep the model's words and timings; corrections go into the text formats."
                        : "Corrections are saved in the library. An export is a separate file to share or keep."
                )
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

    /// The name of each format, here and in the save panel.
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
    /// and the place, and macOS is what asks before replacing a file. Its
    /// Format menu and Timecodes box start on the inspector's choices; other
    /// choices there become the transcript's.
    static func exportAs(_ entry: Entry, with model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Transcript.suggestedName(
            for: entry.name, of: entry.recording, partial: entry.isPartial)
        let choice = FormatChoice(
            panel: panel, formats: formats(for: entry), format: entry.exportFormat,
            times: entry.exportsTimes)
        panel.accessoryView = choice.view
        panel.directoryURL = entry.location.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.export(entry.id, as: choice.format, times: choice.times, to: destination)
    }
}

/// The Format menu and Timecodes box of the save panel. The menu keeps the
/// file's extension in step with the format; subtitles have no Timecodes box,
/// as they are timed already.
private final class FormatChoice: NSObject {
    private(set) var format: Transcript.Format
    var times: Bool { timecodes.state == .on }
    let view: NSView
    private let panel: NSSavePanel
    private let formats: [Transcript.Format]
    private let menu = NSPopUpButton()
    private let timecodes = NSButton(
        checkboxWithTitle: String(localized: "Timecodes"), target: nil, action: nil)

    init(panel: NSSavePanel, formats: [Transcript.Format], format: Transcript.Format, times: Bool) {
        self.panel = panel
        self.formats = formats
        self.format = format
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        let row = NSStackView(views: [label, menu, timecodes])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        view = row
        super.init()
        for choice in formats {
            menu.addItem(withTitle: EntryExportSection.title(of: choice))
        }
        menu.selectItem(at: formats.firstIndex(of: format) ?? 0)
        menu.target = self
        menu.action = #selector(chose(_:))
        timecodes.state = times ? .on : .off
        follow()
    }

    @objc private func chose(_ sender: NSPopUpButton) {
        format = formats[sender.indexOfSelectedItem]
        follow()
    }

    private func follow() {
        timecodes.isHidden = format == .subtitles
        panel.allowedContentTypes =
            switch format {
            case .markdown: [UTType(filenameExtension: "md") ?? .plainText]
            case .word: [UTType(filenameExtension: "docx") ?? .data]
            case .subtitles: [UTType(filenameExtension: "srt") ?? .plainText]
            case .plainText: [.plainText]
            }
    }
}
