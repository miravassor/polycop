// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What the recordings not started yet are transcribed with, beside the page in
/// the system's inspector, as a transcript's page has its own: a grouped form,
/// one setting a row. Those already started keep theirs.
struct NewTranscriptionSettings: View {
    @Bindable var model: AppModel
    @Binding var editingGlossaries: Bool

    private var chosen: Model { model.selectedCatalogue ?? ModelCatalog.recommended }

    var body: some View {
        Form {
            Section("Transcription Settings") {
                LabeledContent("Model") {
                    Menu {
                        Picker("Model", selection: $model.selected) {
                            ForEach(ModelCatalog.all) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Divider()
                        Button("Manage Models…") { model.isManagingModels = true }
                    } label: {
                        Text(chosen.name)
                    }
                    .fixedSize()
                }
                .help(LocalizedStringKey(chosen.engine.features(aligned: model.canAlignQwen)))
                if model.downloadingModel != nil {
                    ModelTransferStatus(model: model)
                } else if !model.isInstalled(chosen.id) {
                    download
                }
                if model.languageApplies {
                    language
                }
                glossary
                if model.silenceApplies {
                    Toggle(isOn: $model.skipsSilence) {
                        Text("Skip silences")
                        Text("Can be faster and invent less, but may leave out quiet speech.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The language spoken.
    private var language: some View {
        let current = DecodingSettings.languages.first { $0.code == model.language }
        return LabeledContent {
            // A menu as the rows beside it, which end with Manage….
            Menu {
                Picker("Language", selection: $model.language) {
                    ForEach(DecodingSettings.languages, id: \.code) { language in
                        Text(LocalizedStringKey(language.name)).tag(language.code)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(LocalizedStringKey(current?.name ?? model.language))
            }
            .fixedSize()
        } label: {
            Text("Language")
            if !Hesitations.cover(model.language) {
                Text("Some automatic cleaning covers only French and English.")
            }
        }
    }

    @ViewBuilder private var glossary: some View {
        if model.glossaryApplies {
            LabeledContent("Glossary") {
                Menu {
                    Picker("Glossary", selection: $model.glossaryName) {
                        Text("None").tag(String?.none)
                        ForEach(model.glossaries) { glossary in
                            Text(glossary.name).tag(String?.some(glossary.name))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button("Manage Glossaries…") { editingGlossaries = true }
                } label: {
                    Text(model.glossaryName ?? String(localized: "None"))
                }
                .fixedSize()
            }
            .help("Helps recognize names, authors and specialist terms")
        } else {
            LabeledContent("Glossary", value: String(localized: "Not used by this model"))
        }
    }

    /// A model not on this Mac yet: Start downloads it first, or it can be
    /// fetched now.
    private var download: some View {
        LabeledContent {
            Button("Download") { model.download(chosen) }
                .disabled(model.stage.isBusy)
        } label: {
            Label {
                Text("Not on This Mac")
                Text(
                    "\(formattedFileSize(chosen.bytes)) once, then offline. \(chosen.license) license."
                )
            } icon: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            }
        }
    }
}
