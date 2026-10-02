// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Exporting, and everything else a finished transcript can be put
/// through. The first export asks where to put the file, as any Mac
/// application does; an update writes over what it wrote before.
struct EntryExportCard: View {
    let model: AppModel
    let entry: Entry
    let isRunning: Bool
    let engine: Engine?
    @State private var showingExportOptions = false

    var body: some View {
        if !isRunning && !entry.paragraphs.isEmpty {
            // A card like those of the New transcription page, the last step of
            // the page.
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        entry.subtitles && entry.timesSentences
                            ? "Export text and original subtitles" : "Export text"
                    )
                    .font(.headline)
                    exported
                }
                Spacer(minLength: 8)
                Button {
                    showingExportOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .iconControl()
                .accessibilityLabel("Export options")
                .help("Export options")
                .popover(isPresented: $showingExportOptions) {
                    EntryExportOptions(
                        entry: entry, isRunning: isRunning, engine: engine,
                        setSubtitles: { model.setSubtitles($0, for: entry.id) },
                        setTextLayout: { model.setTextLayout($0, for: entry.id) },
                        setRemovesHesitations: {
                            model.setRemovesHesitations($0, for: entry.id)
                        })
                }
                export
            }
            .panel()
        }
    }

    /// One button, whose meaning follows the file rather than the saved
    /// record, so a user whose export was deleted or moved is never left
    /// pressing a button that does nothing. Its shortcuts are File menu
    /// commands, which also work when typing has just changed the state.
    @ViewBuilder
    private var export: some View {
        switch model.exportState(of: entry) {
        case .none, .missing:
            Button("Export Text As…") { Self.exportAs(entry, with: model) }
                .buttonStyle(.borderedProminent)
        case .outOfDate:
            Button("Update Export") { model.updateExport(entry.id) }
                .buttonStyle(.borderedProminent)
        case .current:
            Button("Update Export") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }

    @ViewBuilder
    private var exported: some View {
        switch model.exportState(of: entry) {
        case .none:
            Text("Create a separate file to share or keep.")
                .font(.callout).foregroundStyle(.secondary)
        case .missing:
            Text("The previous export was moved or deleted.")
                .font(.callout).foregroundStyle(.secondary)
        case .current, .outOfDate:
            if let first = entry.saved.first {
                Text(
                    model.exportState(of: entry) == .outOfDate
                        ? "Export needs updating: \(first.lastPathComponent)"
                        : "Export is up to date: \(first.lastPathComponent)"
                )
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// The save panel every Mac application uses, so the user chooses the name
    /// and the place, and macOS is what asks before replacing a file.
    static func exportAs(_ entry: Entry, with model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Transcript.suggestedName(
            for: entry.name, partial: entry.isPartial)
        panel.allowedContentTypes =
            switch entry.exportLayout {
            case .markdown: [UTType(filenameExtension: "md") ?? .plainText]
            case .word: [UTType(filenameExtension: "docx") ?? .data]
            case .timestamped, .plain: [.plainText]
            }
        panel.directoryURL = entry.location.deletingLastPathComponent()
        panel.canCreateDirectories = true
        if entry.subtitles && entry.timesSentences {
            panel.message = String(
                localized: "The subtitles are written beside the text, under the same name.")
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.export(entry.id, to: destination)
    }
}
