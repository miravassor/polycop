// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The settings a transcript was made with, shown in a popover from the info button.
struct EntryDetailsPopover: View {
    let entry: Entry
    let engine: Engine?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription details").font(.headline)
            LabeledContent(
                "Added", value: entry.added.formatted(date: .abbreviated, time: .shortened))
            if let source = entry.importSource {
                LabeledContent("Imported from", value: source)
            } else {
                LabeledContent(
                    "Model", value: ModelCatalog.model(entry.modelFile)?.name ?? entry.modelFile)
            }
            if let elapsed = entry.transcribedIn {
                LabeledContent("Transcribed in", value: formattedDuration(elapsed))
            }
            if engine?.audioCpp?.setsLanguage == false {
                LabeledContent("Language", value: "Detected automatically")
            } else if entry.importSource == nil, let code = entry.language,
                let language = DecodingSettings.languages.first(where: { $0.code == code })
            {
                LabeledContent("Language") { Text(LocalizedStringKey(language.name)) }
            }
            if let glossary = entry.glossary {
                LabeledContent("Glossary", value: glossary)
            }
            if entry.skipsSilence { Text("Silences skipped").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 380)
        .textSelection(.enabled)
    }
}
