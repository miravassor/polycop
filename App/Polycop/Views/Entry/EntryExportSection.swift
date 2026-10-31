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
                    ForEach(Transcript.Format.allCases, id: \.self) {
                        Text(Self.title(of: $0)).tag($0)
                    }
                }
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
                if entry.timesSentences {
                    Toggle(
                        "Subtitles (SRT)",
                        isOn: Binding(
                            get: { entry.subtitles }, set: { model.setSubtitles($0, for: entry.id) }
                        )
                    )
                    .help(
                        "Written beside the text, under the same name. Corrections appear in the text; subtitles keep the original words and timings."
                    )
                }
                lastExport
                Button {
                    Self.exportAs(entry, with: model)
                } label: {
                    Text("Export Text…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Make a new file of the text (Command-S)")
            } header: {
                Text("Export")
            } footer: {
                Text(
                    "Corrections are saved in the library. An export is a separate file to share or keep."
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
        }
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
            panel: panel, format: entry.exportFormat, times: entry.exportsTimes)
        panel.accessoryView = choice.view
        panel.directoryURL = entry.location.deletingLastPathComponent()
        panel.canCreateDirectories = true
        if entry.subtitles && entry.timesSentences {
            panel.message = String(
                localized: "The subtitles are written beside the text, under the same name.")
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.export(entry.id, as: choice.format, times: choice.times, to: destination)
    }
}

/// The Format menu and Timecodes box of the save panel. The menu keeps the
/// file's extension in step with the format.
private final class FormatChoice: NSObject {
    private(set) var format: Transcript.Format
    var times: Bool { timecodes.state == .on }
    let view: NSView
    private let panel: NSSavePanel
    private let menu = NSPopUpButton()
    private let timecodes = NSButton(
        checkboxWithTitle: String(localized: "Timecodes"), target: nil, action: nil)

    init(panel: NSSavePanel, format: Transcript.Format, times: Bool) {
        self.panel = panel
        self.format = format
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        let row = NSStackView(views: [label, menu, timecodes])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        view = row
        super.init()
        for choice in Transcript.Format.allCases {
            menu.addItem(withTitle: EntryExportSection.title(of: choice))
        }
        menu.selectItem(at: Transcript.Format.allCases.firstIndex(of: format) ?? 0)
        menu.target = self
        menu.action = #selector(chose(_:))
        timecodes.state = times ? .on : .off
        allowTypes()
    }

    @objc private func chose(_ sender: NSPopUpButton) {
        format = Transcript.Format.allCases[sender.indexOfSelectedItem]
        allowTypes()
    }

    private func allowTypes() {
        panel.allowedContentTypes =
            switch format {
            case .markdown: [UTType(filenameExtension: "md") ?? .plainText]
            case .word: [UTType(filenameExtension: "docx") ?? .data]
            case .plainText: [.plainText]
            }
    }
}
