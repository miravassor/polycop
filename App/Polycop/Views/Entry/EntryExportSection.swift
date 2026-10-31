// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The export, a section of the inspector: the format and its choices on rows,
/// then the buttons. The first export asks where to put the file, as any Mac
/// application does; an update writes over what it wrote before.
struct EntryExportSection: View {
    let model: AppModel
    let entry: Entry
    let isRunning: Bool
    let engine: Engine?

    var body: some View {
        if !isRunning && !entry.paragraphs.isEmpty {
            Section {
                Picker(
                    "Format",
                    selection: Binding(
                        get: { entry.exportLayout },
                        set: { model.setTextLayout($0, for: entry.id) })
                ) {
                    ForEach(Transcript.TextLayout.allCases, id: \.self) {
                        Text(Self.title(of: $0)).tag($0)
                    }
                }
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
                HStack(spacing: 8) { export }
            } header: {
                Text("Export")
            } footer: {
                footer
            }
        }
    }

    @ViewBuilder private var lastExport: some View {
        let state = model.exportState(of: entry)
        if state == .current || state == .outOfDate, let first = entry.saved.first {
            LabeledContent {
                Text(first.lastPathComponent).lineLimit(1).truncationMode(.middle)
            } label: {
                Text("Last Export")
                Text(state == .outOfDate ? "Needs updating" : "Up to date")
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.exportState(of: entry) {
        case .none:
            Text(
                "Corrections are saved in the library. An export is a separate file to share or keep."
            )
        case .missing:
            Text("The previous export was moved or deleted.")
        case .current, .outOfDate:
            EmptyView()
        }
    }

    /// The main button's meaning follows the file rather than the saved
    /// record, so a user whose export was deleted or moved is never left
    /// pressing a button that does nothing. Once there is an export, Export
    /// As… stays beside it, for another copy or another format. The shortcuts
    /// are File menu commands, which also work when typing has just changed
    /// the state.
    @ViewBuilder
    private var export: some View {
        switch model.exportState(of: entry) {
        case .none, .missing:
            Button {
                Self.exportAs(entry, with: model)
            } label: {
                Text("Export Text As…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        case .outOfDate, .current:
            Button {
                Self.exportAs(entry, with: model)
            } label: {
                Text("Export As…").frame(maxWidth: .infinity)
            }
            Button {
                model.updateExport(entry.id)
            } label: {
                Text("Update Export").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.exportState(of: entry) == .current)
        }
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

    /// The save panel every Mac application uses, so the user chooses the name
    /// and the place, and macOS is what asks before replacing a file. Its
    /// Format menu starts on the format chosen in the inspector; another
    /// choice there becomes the transcript's export format.
    static func exportAs(_ entry: Entry, with model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Transcript.suggestedName(
            for: entry.name, of: entry.recording, partial: entry.isPartial)
        let format = FormatChoice(panel: panel, layout: entry.exportLayout)
        panel.accessoryView = format.view
        panel.directoryURL = entry.location.deletingLastPathComponent()
        panel.canCreateDirectories = true
        if entry.subtitles && entry.timesSentences {
            panel.message = String(
                localized: "The subtitles are written beside the text, under the same name.")
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.export(entry.id, as: format.layout, to: destination)
    }
}

/// The Format menu of the save panel, which keeps the file's extension in
/// step with the format.
private final class FormatChoice: NSObject {
    private(set) var layout: Transcript.TextLayout
    let view: NSView
    private let panel: NSSavePanel
    private let menu = NSPopUpButton()

    init(panel: NSSavePanel, layout: Transcript.TextLayout) {
        self.panel = panel
        self.layout = layout
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        let row = NSStackView(views: [label, menu])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        view = row
        super.init()
        for choice in Transcript.TextLayout.allCases {
            menu.addItem(withTitle: EntryExportSection.title(of: choice))
        }
        menu.selectItem(at: Transcript.TextLayout.allCases.firstIndex(of: layout) ?? 0)
        menu.target = self
        menu.action = #selector(chose(_:))
        allowTypes()
    }

    @objc private func chose(_ sender: NSPopUpButton) {
        layout = Transcript.TextLayout.allCases[sender.indexOfSelectedItem]
        allowTypes()
    }

    private func allowTypes() {
        panel.allowedContentTypes =
            switch layout {
            case .markdown: [UTType(filenameExtension: "md") ?? .plainText]
            case .word: [UTType(filenameExtension: "docx") ?? .data]
            case .timestamped, .plain: [.plainText]
            }
    }
}
