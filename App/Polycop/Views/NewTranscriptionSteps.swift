// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// The numbered heading of a step of the New transcription page, so the page
/// reads in order: recordings, settings, start.
struct StepHeading: View {
    let number: Int
    let title: LocalizedStringKey

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "\(number).circle.fill").foregroundStyle(.tint)
        }
        .font(.title3.weight(.semibold))
    }
}

/// Step one: recordings dropped or chosen, and those waiting, by name.
struct RecordingsStep: View {
    let model: AppModel
    let choose: () -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeading(number: 1, title: "Recordings")
            Group {
                if model.waiting.isEmpty { dropHere } else { waiting }
            }
            .panel(isHighlighted: isTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                model.transcribe(urls)
                return !urls.isEmpty
            } isTargeted: {
                isTargeted = $0
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var dropHere: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop recordings here").font(.headline)
                Text("Audio or video, one file or several.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose Recordings…", action: choose).fixedSize()
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(
                    model.waiting.count == 1
                        ? "1 recording" : "\(model.waiting.count) recordings"
                )
                .font(.headline)
                Spacer(minLength: 12)
                Button("Clear", action: model.clearQueue)
                    .help("Take the recordings waiting out of the library")
                Button("Add More…", action: choose)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.waiting) { row($0) }
            }
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.isVideo(entry.recording) ? "film" : "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                model.removeEntry(entry.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(entry.name)")
            .help("Take it out of the queue")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private static func isVideo(_ recording: URL) -> Bool {
        UTType(filenameExtension: recording.pathExtension)?.conforms(to: .movie) == true
    }
}

/// Step three: what starting does, said in one line, and the one button that
/// does it. While a recording runs, the step offers what can be done then.
struct StartStep: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeading(number: 3, title: "Start")
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                button
            }
            .panel()
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .notice(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch model.startAction {
        case .nothing: "Nothing to transcribe yet"
        case .start(let count), .waitingForSave(let count):
            count == 1 ? "1 recording ready" : "\(count) recordings ready"
        case .addToQueue(let count):
            count == 1 ? "1 recording added" : "\(count) recordings added"
        case .showProgress(let name, _): "Transcribing \(name)"
        }
    }

    private var detail: LocalizedStringKey {
        switch model.startAction {
        case .nothing: "Add recordings in step 1, check the settings, then start here."
        case .start: settings
        case .addToQueue:
            model.running == nil
                ? "Transcribed with these settings once the model has downloaded."
                : "Transcribed with these settings after the one running now."
        case .showProgress(_, let waiting):
            waiting == 0
                ? "Recordings added now are transcribed next."
                : waiting == 1 ? "1 more waiting." : "\(waiting) more waiting."
        case .waitingForSave: "Starting waits until the library is saved."
        }
    }

    /// The settings the recordings will be transcribed with, in one line.
    private var settings: LocalizedStringKey {
        let chosen = model.selectedCatalogue ?? ModelCatalog.recommended
        let language =
            chosen.engine.audioCpp?.setsLanguage == false
            ? String(localized: "Language detected")
            : DecodingSettings.languages.first { $0.code == model.language }
                .map { String(localized: String.LocalizationValue($0.name)) } ?? model.language
        var parts = [chosen.name, language]
        if model.glossaryApplies, let glossary = model.glossaryName {
            parts.append(String(localized: "Glossary \(glossary)"))
        }
        if !model.isInstalled(chosen.id) {
            parts.append(String(localized: "Downloads \(formattedFileSize(chosen.bytes)) first"))
        }
        return "\(parts.joined(separator: " · "))"
    }

    @ViewBuilder private var button: some View {
        switch model.startAction {
        case .addToQueue:
            Button("Add to Queue") { model.addToQueue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .showProgress:
            Button("Show Progress") {
                if let running = model.running { model.pane = .entry(running) }
            }
            .controlSize(.large)
        default:
            Button("Start Transcription") { model.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStart)
        }
    }
}
