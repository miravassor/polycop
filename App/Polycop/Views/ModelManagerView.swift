// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Choosing, downloading and removing transcription models, in their own sheet.
struct ModelManagerView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var importingModel: Bool
    @State private var removingModel: Model?
    @State private var removingImported: ModelStore.Imported?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Models").font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 24)
            // Grouped rows as the inspector beside the page, one section an
            // engine, without a colour of its own.
            Form {
                ForEach(Engine.allCases, id: \.self) { engine($0) }
                imported
            }
            .formStyle(.grouped)
            if let failure = model.failure {
                Label(failure, systemImage: "xmark.octagon")
                    .notice(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
            }
            HStack {
                Button("Import Downloaded Model…") { importingModel = true }
                    .disabled(model.stage.isBusy)
                    .help(
                        "Only unchanged catalogue models are accepted; their SHA-256 is verified before use."
                    )
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
        }
        .frame(width: 620, height: 600)
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

    /// An engine's models, with who made it on the title line and what it
    /// can do under them.
    private func engine(_ engine: Engine) -> some View {
        Section {
            ForEach(ModelCatalog.all.filter { $0.engine == engine }) { row($0) }
            if engine == .qwen { aligner }
        } header: {
            HStack {
                Text(engine.name)
                Spacer()
                Text(engine.developer).foregroundStyle(.secondary).fontWeight(.regular)
            }
        } footer: {
            Text(LocalizedStringKey(engine.features(aligned: model.canAlignQwen)))
                .help(LocalizedStringKey(Engine.wordTimings))
        }
    }

    /// A model: its name, what it is good at, its size and licence, and what
    /// can be done with it at the trailing edge.
    @ViewBuilder private func row(_ item: Model) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if model.installed.contains(item.id) {
                    if model.selected == item.id {
                        Label("In Use", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Button("Use") { model.selected = item.id }
                    }
                    Menu {
                        Button("Delete…", role: .destructive) { removingModel = item }
                            .disabled(model.stage.isBusy || model.isNeeded(item.id))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Actions for \(item.name)")
                } else if model.downloadingModel?.id != item.id {
                    Button("Download and Use") {
                        model.selected = item.id
                        model.download(item)
                    }
                    .disabled(model.stage.isBusy)
                }
            }
        } label: {
            Text(item.name)
            Text(LocalizedStringKey(item.detail))
            Text("\(formattedFileSize(item.bytes)) · \(item.license) license")
        }
        if model.downloadingModel?.id == item.id { ModelTransferStatus(model: model) }
    }

    /// Models imported by hand, which the catalogue does not vouch for.
    @ViewBuilder private var imported: some View {
        if !model.imported.isEmpty {
            Section("Imported") {
                ForEach(model.imported) { item in
                    LabeledContent {
                        Button("Delete…", role: .destructive) { removingImported = item }
                            .disabled(model.stage.isBusy)
                    } label: {
                        Text(item.name)
                        Text("Unverified · \(formattedFileSize(item.bytes))")
                    }
                }
            }
        }
    }

    /// Qwen's optional aligner: not a model to transcribe with, so it has a
    /// download and a delete, and no Use.
    @ViewBuilder private var aligner: some View {
        let item = ModelCatalog.qwenAligner
        LabeledContent {
            if model.alignerInstalled {
                Button("Delete…", role: .destructive) { removingModel = item }
                    .disabled(model.stage.isBusy)
            } else if model.downloadingModel?.id != item.id {
                Button("Download") { model.download(item) }
                    .disabled(model.stage.isBusy)
            }
        } label: {
            Text(item.name)
            Text("Optional. \(item.detail).")
            Text("\(formattedFileSize(item.bytes)) · \(item.license) license")
        }
        if model.downloadingModel?.id == item.id { ModelTransferStatus(model: model) }
    }
}
