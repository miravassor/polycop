// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct TranscriptImportView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var transcript: URL?
    @State private var audio: URL?
    @State private var choosing = false
    @State private var choosingTranscript = true
    @State private var importing = false
    @State private var closing = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Import transcript and audio").font(.title2.weight(.semibold))
            Text(
                "Correct an existing transcript while listening to its recording. The source files stay unchanged."
            )
            .foregroundStyle(.secondary)
            fileRow("Transcript", file: transcript, transcript: true)
            fileRow("Recording", file: audio, transcript: false)
            Text(
                "Timestamped TXT or Word document, SRT, VTT and Whisper/audio.cpp JSON. audio.cpp sample offsets use 16 kHz unless the JSON declares a sample rate."
            )
            .font(.caption).foregroundStyle(.secondary)
            Text(
                "Choose the matching recording. Timestamps are checked against its duration; the spoken words are not verified."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            HStack(spacing: 12) {
                if importing {
                    ProgressView().controlSize(.small)
                    Text(closing ? "Stopping…" : "Checking transcript and audio…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    if importing {
                        closing = true
                        model.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(closing)
                Button("Import") {
                    guard let transcript, let audio else { return }
                    problem = nil
                    importing = true
                    model.importTranscript(transcript, audio: audio)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(transcript == nil || audio == nil || model.stage.isBusy || importing)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(importing)
        .fileImporter(
            isPresented: $choosing,
            allowedContentTypes: choosingTranscript ? [.data] : [.audio, .movie]
        ) { result in
            switch result {
            case .success(let file):
                if choosingTranscript { transcript = file } else { audio = file }
                problem = nil
            case .failure(let error): problem = error.localizedDescription
            }
        }
        .onChange(of: model.stage) {
            guard importing, !model.stage.isBusy else { return }
            importing = false
            if closing || model.failure == nil { dismiss() } else { problem = model.failure }
        }
        .onChange(of: model.pane) {
            if importing, case .entry(let id) = model.pane, model.entry(id)?.importSource != nil {
                importing = false
                dismiss()
            }
        }
    }

    private func fileRow(_ label: LocalizedStringKey, file: URL?, transcript: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label).fontWeight(.medium).frame(width: 85, alignment: .leading)
            Text(file?.lastPathComponent ?? "No file selected")
                .foregroundStyle(file == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") {
                choosingTranscript = transcript
                choosing = true
            }
            .disabled(importing)
        }
    }
}
