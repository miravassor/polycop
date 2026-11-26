// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The settings a transcript was made with, so a result can be judged later:
/// a section of the inspector, which shows the details of what is open.
struct EntryDetails: View {
    let facts: Facts
    let reading: ReadingSettings

    /// What the details section shows of the transcript, which a correction
    /// typed in the text leaves as it is.
    struct Facts: Equatable {
        var added: Date
        var importSource: String?
        var modelName: String
        var transcribedIn: TimeInterval?
        var isLanguageDetected: Bool
        var language: String?
        var glossary: String?
        var skipsSilence: Bool
    }

    var body: some View {
        // Selection on the rows only: the title is a button.
        FoldingSection(.details, reading: reading) {
            rows.textSelection(.enabled)
        }
    }

    @ViewBuilder private var rows: some View {
        LabeledContent(
            "Added", value: facts.added.formatted(date: .abbreviated, time: .shortened))
        if let source = facts.importSource {
            LabeledContent("Imported from", value: source)
        } else {
            LabeledContent("Model", value: facts.modelName)
        }
        if let elapsed = facts.transcribedIn {
            LabeledContent("Transcribed in", value: formattedDuration(elapsed))
        }
        if facts.isLanguageDetected {
            LabeledContent("Language", value: "Detected automatically")
        } else if let language = facts.language {
            LabeledContent("Language") { Text(LocalizedStringKey(language)) }
        }
        if let glossary = facts.glossary {
            LabeledContent("Glossary", value: glossary)
        }
        if facts.skipsSilence { LabeledContent("Silences", value: "Skipped") }
    }
}

extension EntryDetails.Facts {
    init(_ entry: Entry) {
        self.init(
            added: entry.added,
            importSource: entry.importSource,
            modelName: ModelCatalog.model(entry.modelFile)?.name ?? entry.modelFile,
            transcribedIn: entry.transcribedIn,
            isLanguageDetected: entry.isLanguageDetected,
            language: entry.toldLanguage.flatMap(DecodingSettings.name(of:)),
            glossary: entry.glossary,
            skipsSilence: entry.skipsSilence)
    }
}
