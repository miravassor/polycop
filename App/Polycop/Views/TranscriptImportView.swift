// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct TranscriptImportView: View {
    /// File types accepted by `TranscriptImport.parse`: plain text, Word,
    /// SRT, VTT and JSON. Every type registered for `docx`, `srt` and `vtt`
    /// is included because macOS and installed apps can declare more than
    /// one identifier for those extensions.
    nonisolated static var transcriptTypes: [UTType] {
        [.plainText, .json]
            + ["docx", "srt", "vtt"].flatMap {
                UTType.types(tag: $0, tagClass: .filenameExtension, conformingTo: .data)
            }
    }

    private enum FileKind {
        case transcript
        case recording

        var allowedContentTypes: [UTType] {
            switch self {
            case .transcript: TranscriptImportView.transcriptTypes
            case .recording: [.audio, .movie]
            }
        }
    }

    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var transcript: URL?
    @State private var audio: URL?
    @State private var choosing = false
    @State private var choosingKind: FileKind = .transcript
    @State private var importing = false
    @State private var closing = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Import transcript and recording").font(.sheetTitle)
            Text(
                "Correct an existing transcript while listening to its recording. The source files stay unchanged."
            )
            .foregroundStyle(.secondary)
            fileRow("Transcript", file: transcript, kind: .transcript)
            fileRow("Recording", file: audio, kind: .recording)
            Text(
                "Timestamped TXT or Word document, SRT, VTT and Whisper/audio.cpp JSON. audio.cpp sample offsets use 16 kHz unless the JSON declares a sample rate."
            )
            .font(.caption).foregroundStyle(.secondary)
            Text(
                "Choose the matching recording. Timestamps are checked against its duration; the spoken words are not verified."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let problem {
                Notice(problem, .failure)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 12) {
                if importing {
                    ProgressView().controlSize(.small)
                    Text(closing ? "Stopping…" : "Checking transcript and recording…")
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
                    Task {
                        do {
                            try await model.importTranscript(transcript, audio: audio)
                            dismiss()
                        } catch {
                            if closing { dismiss() } else { problem = error.localizedDescription }
                        }
                        importing = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(transcript == nil || audio == nil || model.stage.isBusy || importing)
            }
        }
        .padding(Spacing.sheet)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(importing)
        // One importer for both rows: SwiftUI honours only one `.fileImporter`
        // on a view, so both rows share this modifier on the sheet root.
        .fileImporter(
            isPresented: $choosing,
            allowedContentTypes: choosingKind.allowedContentTypes
        ) { result in
            switch result {
            case .success(let file):
                switch choosingKind {
                case .transcript: transcript = file
                case .recording: audio = file
                }
                problem = nil
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    private func fileRow(_ label: LocalizedStringKey, file: URL?, kind: FileKind) -> some View {
        HStack(spacing: 12) {
            Text(label).fontWeight(.medium).frame(width: 85, alignment: .leading)
            Text(file?.lastPathComponent ?? "No file selected")
                .foregroundStyle(file == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") {
                choosingKind = kind
                choosing = true
            }
            .disabled(importing)
        }
    }
}
