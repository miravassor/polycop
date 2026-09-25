// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct NewTranscriptionView: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var targeted = false
    @State private var importingModel = false
    @State private var optionsExpanded = false
    @State private var managingModels = false
    @State private var editingGlossaries = false

    private var isReady: Bool { model.isInstalled(model.selected) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New transcription")
                        .font(.title2.weight(.semibold))
                    Text("Add recordings, choose your settings, then start.")
                        .foregroundStyle(.secondary)
                }
                dropZone
                Button("Import Transcript and Audio…") { model.chooseTranscriptImport() }
                    .disabled(model.stage.isBusy)
                    .help("Edit an existing timestamped transcript with its recording")
                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                settings
                queue
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $editingGlossaries) { GlossaryEditor(model: model) }
        .sheet(isPresented: $managingModels) {
            ModelManagerView(model: model, importingModel: $importingModel)
        }
        .task(id: model.recordingsRequest) {
            guard model.recordingsRequest != nil else { return }
            model.recordingsRequest = nil
            importingModel = false
            importing = true
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

    /// What has been added and not yet started. Transcribing takes the machine
    /// for minutes, so it begins only when the user says so.
    @ViewBuilder
    private var queue: some View {
        if model.canStart {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        model.waiting.count == 1
                            ? "1 recording is waiting"
                            : "\(model.waiting.count) recordings are waiting"
                    )
                    .font(.headline)
                    Text(
                        (!isReady ? model.selectedCatalogue : nil).map {
                            LocalizedStringKey("\($0.name) is downloaded first.")
                        }
                            ?? "They are transcribed one at a time, in the order you added them."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Clear Queue") { model.clearQueue() }
                        .help("Takes the recordings waiting out of the library")
                    Spacer()
                    Button("Start Transcription") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dropZone: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                dropLabel
                Spacer(minLength: 12)
                chooseRecordings
            }
            VStack(alignment: .leading, spacing: 12) {
                dropLabel
                chooseRecordings
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            targeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    targeted ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.transcribe(urls)
            return !urls.isEmpty
        } isTargeted: {
            targeted = $0
        }
    }

    private var dropLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Add recordings").font(.headline)
                Text("Drop audio or video files here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var chooseRecordings: some View {
        Button("Choose Recordings…") {
            importingModel = false
            importing = true
        }
        .controlSize(.regular)
        .fixedSize()
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
                Text("Start Transcription also downloads it if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Defaults for recordings that have not started.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Recordings already started keep their settings.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
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
                    .frame(width: 240, alignment: .leading)
                    .disabled(model.selectedCatalogue?.engine.audioCpp?.setsLanguage == false)
                    if model.selectedCatalogue?.engine.audioCpp?.setsLanguage == false {
                        Text("This model detects the spoken language automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            settingRow("Glossary") { glossary }
            Divider()
            if model.silenceApplies { options }
        }
        .pickerStyle(.menu)
        .controlSize(.regular)
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
                .frame(width: 240, alignment: .leading)
                .disabled(!model.glossaryApplies)
                .accessibilityHint("Used for recordings that have not started.")
                Button("Manage…") { editingGlossaries = true }
                    .accessibilityLabel("Manage glossaries")
                    .help("Create, import and edit course glossaries")
            }
            Text(
                model.glossaryApplies
                    ? "Optional. Help recognize names, authors and specialist terms."
                    : "Available with Whisper and MOSS. Not used by this model."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                .frame(width: 240, alignment: .leading)
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
