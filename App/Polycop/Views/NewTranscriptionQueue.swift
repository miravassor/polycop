// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The recordings waiting, by name, in grouped rows as the settings beside
/// them, with the one button that starts right under them.
struct RecordingsQueue: View {
    let model: AppModel
    let showsSettings: Bool
    let choose: () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(model.waiting) { row($0) }
            } header: {
                // Adding and clearing on the list's title line, aligned with
                // its trailing edge, so Start alone sits under the list.
                HStack(spacing: 12) {
                    Text(
                        model.waiting.count == 1
                            ? "1 Recording" : "\(model.waiting.count) Recordings")
                    Spacer(minLength: 12)
                    // Capsules as Start below, the removal last.
                    Button("Add More…", systemImage: "plus", action: choose)
                    Button("Clear", systemImage: "xmark", action: model.clearQueue)
                        .help("Take the recordings waiting out of the library")
                }
                .buttonBorderShape(.capsule)
            } footer: {
                StartBar(model: model, showsSettings: showsSettings)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: entry.isVideo ? "film" : "waveform")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            Spacer(minLength: 8)
            Button {
                model.removeEntry(entry.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(entry.name)")
            .help("Take it out of the queue")
        }
        .contextMenu {
            Button("Remove from Queue") { model.removeEntry(entry.id) }
        }
    }
}

/// The one button that starts, a capsule in the accent colour as large as the
/// player. A line beside it only when there is something to say: what runs,
/// or the settings when the inspector that shows them is hidden.
struct StartBar: View {
    let model: AppModel
    let showsSettings: Bool

    var body: some View {
        if model.startAction != .nothing {
            if let status {
                HStack(spacing: 16) {
                    Text(status)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 14)
                    button
                }
                .padding(6)
                .modifier(FloatingSurface(cornerRadius: 30))
            } else {
                button
            }
        }
    }

    private var status: LocalizedStringKey? {
        switch model.startAction {
        case .nothing: nil
        case .start: showsSettings ? settings : nil
        case .addToQueue:
            model.running == nil
                ? "Transcribed once the model has downloaded."
                : "Transcribed after the one running now."
        case .showProgress(let name, let waiting):
            waiting == 0
                ? "Transcribing \(name)."
                : waiting == 1
                    ? "Transcribing \(name), 1 more waiting."
                    : "Transcribing \(name), \(waiting) more waiting."
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
            ActionButton(title: "Add to Queue", systemImage: "text.badge.plus") {
                model.addToQueue()
            }
        case .showProgress:
            ActionButton(
                title: "Show Progress", systemImage: "arrow.forward.circle", isProminent: false
            ) {
                if let running = model.running { model.pane = .entry(running) }
            }
        default:
            ActionButton(title: "Start Transcription", systemImage: "waveform") { model.start() }
                .disabled(!model.canStart)
        }
    }
}
