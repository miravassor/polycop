// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Imports an existing transcript alongside its recording so the student can
/// listen and correct it in Polycop.
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
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Transcript and Recording").font(.sheetTitle)
                .padding([.horizontal, .top], Spacing.sheet)
            Form {
                Section {
                    fileRow("Transcript", file: transcript, kind: .transcript)
                    fileRow("Recording", file: audio, kind: .recording)
                } footer: {
                    Text(
                        "SRT, VTT, or a timestamped TXT, Word or JSON file. Source files stay unchanged; timestamps are checked against the recording's duration, not its spoken words."
                    )
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if let problem {
                Notice(problem, .failure)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Spacing.sheet)
                    .padding(.bottom, Spacing.block)
            }
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
            .padding([.horizontal, .bottom], Spacing.sheet)
        }
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
        LabeledContent {
            Button("Choose…") {
                choosingKind = kind
                choosing = true
            }
            .disabled(importing)
        } label: {
            Text(label)
            Text(file?.lastPathComponent ?? String(localized: "No file selected"))
                .foregroundStyle(file == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

#Preview {
    // An empty library and glossaries of its own, never the user's.
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    TranscriptImportView(
        model: AppModel(
            history: folder.appending(path: "History"),
            glossaries: folder.appending(path: "Glossaries"),
            models: folder.appending(path: "Models"),
            playbackCopies: folder.appending(path: "Copies"),
            defaults: MemoryDefaults()))
}
