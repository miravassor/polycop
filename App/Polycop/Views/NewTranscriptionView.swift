// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// The page that adds recordings and starts them: the recordings in the middle,
/// what they are transcribed with in the inspector, as a transcript's page has
/// its controls there.
struct NewTranscriptionView: View {
    @Bindable var model: AppModel
    /// The inspector, shown, hidden and as wide as on a transcript's page.
    @Binding var showsInspector: Bool
    @Binding var inspectorWidth: Double
    @State private var importing = false
    @State private var importingModel = false
    @State private var managingModels = false
    @State private var editingGlossaries = false
    @State private var isTargeted = false

    var body: some View {
        page
            .navigationTitle("New Transcription")
            .inspector(isPresented: $showsInspector) {
                NewTranscriptionSettings(
                    model: model, managingModels: $managingModels,
                    editingGlossaries: $editingGlossaries
                )
                .modifier(InspectorColumn(isShown: $showsInspector, width: $inspectorWidth))
            }
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

    private var page: some View {
        VStack(spacing: 0) {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .notice(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
            }
            if model.waiting.isEmpty {
                VStack(spacing: 24) {
                    dropHere
                    // What runs while nothing waits, under the empty state.
                    StartBar(model: model, showsSettings: !showsInspector)
                }
                .padding(.bottom, 28)
            } else {
                RecordingsQueue(
                    model: model, showsSettings: !showsInspector, choose: chooseRecordings)
            }
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.transcribe(urls)
            return !urls.isEmpty
        } isTargeted: {
            isTargeted = $0
        }
    }

    private func chooseRecordings() {
        importingModel = false
        importing = true
    }

    /// The system's empty state, with the way to add recordings and, below,
    /// the way to bring a transcript made elsewhere.
    private var dropHere: some View {
        ContentUnavailableView {
            Label {
                Text("Drop Recordings Here")
            } icon: {
                Image(systemName: "waveform.circle").foregroundStyle(.tint)
            }
        } description: {
            Text("Audio or video, one file or several.")
        } actions: {
            // The way to add recordings first, in the accent colour as Start;
            // a transcript made elsewhere as a quieter line under it.
            VStack(spacing: 16) {
                ActionButton(
                    title: "Choose Recordings…", systemImage: "plus", action: chooseRecordings)
                Button(
                    "Import Transcript and Recording…", systemImage: "square.and.arrow.down"
                ) {
                    model.chooseTranscriptImport()
                }
                .buttonStyle(.borderless)
                .disabled(model.stage.isBusy)
                .help("Listen to a transcript made elsewhere and correct it here")
            }
        }
    }
}

/// The current model download or check, shown wherever a transfer can start:
/// what runs and how far, with its way to stop, over the progress bar.
struct ModelTransferStatus: View {
    let model: AppModel

    private var progress: Double? {
        if case .downloading(let progress) = model.stage { progress } else { nil }
    }

    var body: some View {
        if model.stage == .stopping {
            Text("Stopping…").foregroundStyle(.secondary)
        } else if model.stage == .loading || progress != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        Text(model.stage == .loading ? "Checking the model" : "Downloading")
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                    }
                    Spacer()
                    if let progress {
                        Text(percent(progress)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button {
                        model.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel")
                    .help("Cancel")
                }
                if let progress {
                    ProgressView(value: progress).accessibilityLabel("Model download")
                } else {
                    ProgressView().progressViewStyle(.linear).accessibilityLabel("Model check")
                }
            }
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
