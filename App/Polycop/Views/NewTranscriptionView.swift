// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct NewTranscriptionView: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var importingModel = false
    @State private var optionsExpanded = false
    @State private var managingModels = false
    @State private var editingGlossaries = false
    @State private var width: CGFloat = 0

    private var isReady: Bool { model.isInstalled(model.selected) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Side by side when the window is wide, as in full screen,
                // rather than one narrow column beside empty space.
                if width >= 940 {
                    HStack(alignment: .top, spacing: 24) {
                        RecordingsStep(model: model, choose: chooseRecordings)
                        settings
                    }
                } else {
                    RecordingsStep(model: model, choose: chooseRecordings)
                    settings
                }
                StartStep(model: model)
                importTranscript
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = $0
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("New Transcription")
        .sheet(isPresented: $editingGlossaries) { GlossaryEditor(model: model) }
        .sheet(isPresented: $managingModels) {
            ModelManagerView(model: model, importingModel: $importingModel)
        }
        .task(id: model.recordingsRequest) {
            guard model.recordingsRequest != nil else { return }
            model.recordingsRequest = nil
            chooseRecordings()
        }
        .task(id: model.glossariesRequest) {
            guard model.glossariesRequest != nil else { return }
            model.glossariesRequest = nil
            editingGlossaries = true
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let files):
                model.transcribe(files)
            case .failure(let error): model.report(error)
            }
        }
    }

    private func chooseRecordings() {
        importingModel = false
        importing = true
    }

    /// A transcript made elsewhere, corrected here against its recording: a
    /// line apart, so it does not read as another way to add recordings.
    private var importTranscript: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Already have a transcript made elsewhere?").foregroundStyle(.secondary)
            Button {
                model.chooseTranscriptImport()
            } label: {
                Label("Import Transcript and Audio…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.stage.isBusy)
            .help("Listen to a transcript made elsewhere and correct it here")
        }
        .font(.callout)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Download \(formattedFileSize((model.selectedCatalogue ?? ModelCatalog.recommended).bytes)) once to use this model offline."
            )
            .font(.callout).foregroundStyle(.secondary)
            modelLicense(model.selectedCatalogue ?? ModelCatalog.recommended)
            if model.downloadingModel != nil {
                ModelTransferStatus(model: model)
            } else {
                Button("Download Model") {
                    model.download(model.selectedCatalogue ?? ModelCatalog.recommended)
                }
                .disabled(model.stage.isBusy)
            }
        }
    }

    /// Defaults for recordings that have not started.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeading(number: 2, title: "Settings")
                .help("For recordings not started yet. Those already started keep theirs.")
            settingRows.panel()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .pickerStyle(.menu)
        .controlSize(.regular)
    }

    private var settingRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingRow("Model") { transcriptionModel }
            Divider()
            settingRow("Language") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(
                        "Language spoken",
                        selection: $model.language
                    ) {
                        ForEach(DecodingSettings.languages, id: \.code) { language in
                            Text(LocalizedStringKey(language.name)).tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.selectedCatalogue?.engine.audioCpp?.setsLanguage == false)
                    if model.selectedCatalogue?.engine.audioCpp?.setsLanguage == false {
                        Text("This model detects the spoken language automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            settingRow("Glossary") { glossary }
            if model.silenceApplies {
                Divider()
                options
            }
        }
    }

    private func settingRow<Content: View>(
        _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                Text(title).fontWeight(.medium)
                    .frame(width: 90, alignment: .leading).padding(.top, 4)
                content().frame(minWidth: 330, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).fontWeight(.medium)
                content()
            }
        }
    }

    private var glossary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker(
                    "Glossary",
                    selection: $model.glossaryName
                ) {
                    Text("No glossary").tag(String?.none)
                    ForEach(model.glossaries) { glossary in
                        Text(glossary.name).tag(String?.some(glossary.name))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.glossaryApplies)
                .accessibilityHint("Used for recordings that have not started.")
                .help("Optional: helps recognize names, authors and specialist terms")
                Button("Manage…") { editingGlossaries = true }
                    .accessibilityLabel("Manage glossaries")
                    .help("Create, import and edit course glossaries")
            }
            if !model.glossaryApplies {
                Text("Available with Whisper and MOSS. Not used by this model.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The chosen model. Management opens a separate sheet.
    private var transcriptionModel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker(
                    "Transcription model",
                    selection: $model.selected
                ) {
                    ForEach(ModelCatalog.all) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Manage…") { managingModels = true }
                    .accessibilityLabel("Manage models")
            }
            if let selected = model.selectedCatalogue {
                HStack(spacing: 12) {
                    Text(selected.engine.name).fontWeight(.medium)
                    Text(isReady ? "Installed" : "Download required")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                Text(LocalizedStringKey(selected.engine.features(aligned: model.canAlignQwen)))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(LocalizedStringKey(Engine.wordTimings))
            }
            if !isReady { setup }
            if isReady && model.downloadingModel != nil { ModelTransferStatus(model: model) }
        }
    }

    /// Whisper-only settings, with the disclosure label aligned to other sections.
    private var options: some View {
        DisclosureGroup(isExpanded: $optionsExpanded) {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(
                    isOn: $model.skipsSilence
                ) {
                    Text("Skip silences")
                    Text(
                        "May be faster and reduce invented lines, but can omit quiet speech. Off by default."
                    )
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, 14)
        } label: {
            Text("Advanced transcription settings")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The current model download or check, shown wherever a transfer can start.
struct ModelTransferStatus: View {
    let model: AppModel

    var body: some View {
        switch model.stage {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(model.downloadingModel?.name ?? "Model") · \(percent(progress))")
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { model.cancel() }
                }
                ProgressView(value: progress).accessibilityLabel("Model download")
            }
        case .loading:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Checking the model")
                Spacer()
                Button("Cancel") { model.cancel() }
            }
        case .stopping:
            Text("Stopping…").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// A model's license line, wrapped for narrow columns.
func modelLicense(_ item: Model) -> some View {
    Text("Model license: \(item.license)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

func formattedFileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
