// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Choosing, downloading and removing transcription models, in their own sheet.
struct ModelManagerView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Binding var importingModel: Bool
    @State private var removingModel: Model?
    @State private var removingImported: ModelStore.Imported?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Models").font(.title2.weight(.semibold))
            Text(
                "Choose a model for the next batch. Recordings already started keep their settings."
            )
            .foregroundStyle(.secondary)
            ScrollView { models }
            Divider()
            HStack {
                Button("Import Downloaded Model…") { importingModel = true }
                    .disabled(model.stage.isBusy)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if model.downloadingModel != nil { ModelTransferStatus(model: model) }
            if let failure = model.failure {
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(width: 620, height: 570)
        .confirmationDialog(
            "Delete this model?",
            isPresented: Binding(
                get: { removingModel != nil || removingImported != nil },
                set: {
                    if !$0 {
                        removingModel = nil
                        removingImported = nil
                    }
                })
        ) {
            Button("Delete Model", role: .destructive) {
                if let removingModel { model.delete(removingModel) }
                if let removingImported { model.delete(removingImported) }
                removingModel = nil
                removingImported = nil
            }
        } message: {
            Text(
                "Existing transcripts are kept. You will need to download or import the model again to use it."
            )
        }
        .fileImporter(isPresented: $importingModel, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let file): model.importModel(file)
            case .failure(let error): model.report(error)
            }
        }
    }

    private func familyColor(_ engine: Engine) -> Color {
        switch (engine, colorScheme) {
        case (.qwen, .dark): Color(red: 0.70, green: 0.63, blue: 0.94)
        case (.qwen, _): Color(red: 0.40, green: 0.30, blue: 0.72)
        case (.whisper, .dark): Color(red: 0.46, green: 0.77, blue: 0.65)
        case (.whisper, _): Color(red: 0.13, green: 0.43, blue: 0.34)
        case (.moss, .dark): Color(red: 0.49, green: 0.70, blue: 0.90)
        case (.moss, _): Color(red: 0.16, green: 0.38, blue: 0.62)
        case (.voxtral, .dark): Color(red: 0.93, green: 0.64, blue: 0.42)
        case (.voxtral, _): Color(red: 0.66, green: 0.36, blue: 0.13)
        }
    }

    /// Installed and available models, grouped by engine.
    private var models: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(Engine.allCases, id: \.self) { family in
                if family != Engine.allCases.first {
                    Divider().padding(.vertical, 4)
                }
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(family.name).font(.headline)
                                .foregroundStyle(familyColor(family))
                            Spacer()
                            Text(family.developer).font(.callout).foregroundStyle(.secondary)
                        }
                        Text(LocalizedStringKey(family.features(aligned: model.canAlignQwen)))
                            .font(.caption).foregroundStyle(.secondary)
                            .help(LocalizedStringKey(Engine.wordFollowing))
                    }
                    .panel(tint: familyColor(family))
                    ForEach(ModelCatalog.all.filter { $0.engine == family }) { item in
                        Divider()
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.name).fontWeight(.medium)
                                Text(LocalizedStringKey(item.detail))
                                    .font(.callout).foregroundStyle(.secondary)
                                Text(formattedFileSize(item.bytes)).font(.caption)
                                    .foregroundStyle(.secondary)
                                modelLicense(item)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 12) {
                                if model.installed.contains(item.id) {
                                    if model.selected == item.id {
                                        Label("Selected", systemImage: "checkmark")
                                            .font(.callout).foregroundStyle(.tint)
                                    } else {
                                        Button("Use Model") { model.selected = item.id }
                                    }
                                    Menu {
                                        Button("Delete…", role: .destructive) {
                                            removingModel = item
                                        }
                                        .disabled(model.stage.isBusy || model.isNeeded(item.id))
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .frame(width: 16, height: 16)
                                    }
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                    .accessibilityLabel("Actions for \(item.name)")
                                } else {
                                    Button("Download and Use") {
                                        model.selected = item.id
                                        model.download(item)
                                    }
                                    .disabled(model.stage.isBusy)
                                }
                            }
                            .fixedSize()
                        }
                        .padding(.vertical, 4)
                    }
                    if family == .qwen { aligner }
                }
            }
            Text(
                "Only unchanged catalogue models are accepted. Their SHA-256 is verified before use."
            )
            .font(.caption).foregroundStyle(.secondary)
            ForEach(model.imported) { item in
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.name).fontWeight(.medium)
                        Text("Unverified model · \(formattedFileSize(item.bytes))").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete…", role: .destructive) { removingImported = item }
                        .disabled(model.stage.isBusy)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// Qwen's optional aligner: not a model to transcribe with, so it has a
    /// download and a delete, and no Use.
    private var aligner: some View {
        let item = ModelCatalog.qwenAligner
        return VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).fontWeight(.medium)
                    Text(LocalizedStringKey(item.detail))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(
                        "Optional. Used by Qwen3-ASR when installed and within this Mac's memory budget."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Text(formattedFileSize(item.bytes)).font(.caption).foregroundStyle(.secondary)
                    modelLicense(item)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.alignerInstalled {
                    Button("Delete…", role: .destructive) { removingModel = item }
                        .disabled(model.stage.isBusy)
                } else {
                    Button("Download") { model.download(item) }
                        .disabled(model.stage.isBusy)
                }
            }
            .padding(.vertical, 8)
        }
    }
}
