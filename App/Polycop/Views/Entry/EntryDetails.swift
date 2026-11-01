// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The settings a transcript was made with, so a result can be judged later:
/// a section of the inspector, which shows the details of what is open.
struct EntryDetails: View {
    let entry: Entry
    let engine: Engine?

    var body: some View {
        // Selection on the rows only: on the section it also reached the
        // header, which then drew in the text colour, unlike the others.
        Section("Details") { rows.textSelection(.enabled) }
    }

    @ViewBuilder private var rows: some View {
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
        if entry.skipsSilence { LabeledContent("Silences", value: "Skipped") }
    }
}
