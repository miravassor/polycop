// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A transcript with no text yet, or none at all: the system's empty state,
/// centred as on the empty New Transcription page, with the way on when there
/// is one. Work under way shows above it, in its own capsule.
struct EntryEmptyState: View {
    let model: AppModel
    let entry: Entry
    let isRunning: Bool

    var body: some View {
        if isRunning {
            noTextYet("Text appears here as it is transcribed.")
        } else {
            switch entry.state {
            case .waiting, .running:
                waiting
            case .finished:
                ContentUnavailableView {
                    Label {
                        Text("No Speech Detected")
                    } icon: {
                        tinted("waveform.slash")
                    }
                } description: {
                    Text("Listen to the recording to check that it holds speech.")
                }
            case .stopped:
                ContentUnavailableView {
                    Label {
                        Text("Stopped")
                    } icon: {
                        Image(systemName: "stop.circle").foregroundStyle(.orange)
                    }
                } description: {
                    Text("It stopped before any text was written.")
                } actions: {
                    retry
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label {
                        Text("Transcription Failed")
                    } icon: {
                        Image(systemName: "xmark.octagon").foregroundStyle(.red)
                    }
                } description: {
                    Text(message)
                } actions: {
                    retry
                }
            }
        }
    }

    @ViewBuilder private var waiting: some View {
        switch model.waitingStep(for: entry) {
        case .download:
            noTextYet("Transcription starts once the model is downloaded.")
        case .turn(let after):
            ContentUnavailableView {
                Label {
                    Text("Waiting for Its Turn")
                } icon: {
                    tinted("clock")
                }
            } description: {
                if let after {
                    Text("Starts after \(after).")
                } else {
                    Text("Starts after the recordings ahead of it.")
                }
            } actions: {
                if let running = model.running {
                    ActionButton(
                        title: "Show Progress", systemImage: "arrow.forward.circle",
                        isProminent: false
                    ) {
                        model.pane = .entry(running)
                    }
                }
            }
        case .start(let count):
            waitingToStart(count > 1 ? "Starts the \(count) recordings waiting, in order." : nil) {
                // The File menu's Start: a retry keeps the settings it was given.
                ActionButton(title: "Start Transcription", systemImage: "waveform") {
                    if model.isScheduled(entry.id) { model.continueQueue() } else { model.start() }
                }
            }
        case .addToQueue:
            waitingToStart("Add it to start after the one running now.") {
                ActionButton(title: "Add to Queue", systemImage: "text.badge.plus") {
                    model.addToQueue()
                }
            }
        case .save:
            waitingToStart("Starting waits until the library is saved.") { EmptyView() }
        case nil:
            waitingToStart(nil) { EmptyView() }
        }
    }

    /// The settings it starts with, and what starting does when that is not
    /// plain.
    private func waitingToStart(
        _ note: LocalizedStringKey?, @ViewBuilder actions: () -> some View
    ) -> some View {
        ContentUnavailableView {
            Label {
                Text("Waiting to Start")
            } icon: {
                tinted("clock")
            }
        } description: {
            VStack(spacing: 4) {
                Text(settings)
                if let note { Text(note) }
            }
        } actions: {
            actions()
        }
    }

    /// What it is transcribed with: its own settings once scheduled, which a
    /// start keeps, otherwise those on New Transcription, which a start gives it.
    private var settings: String {
        guard model.isScheduled(entry.id) else { return StartBar.summary(of: model) }
        let name = ModelCatalog.model(entry.modelFile)?.name ?? entry.modelFile
        let language = entry.language.flatMap { code in
            DecodingSettings.languages.first { $0.code == code }
        }
        return [name, language.map { String(localized: String.LocalizationValue($0.name)) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var retry: some View {
        ActionButton(title: "Retry", systemImage: "arrow.clockwise") { model.retry(entry.id) }
            .help("Transcribe the recording again with the settings it was given")
    }

    private func noTextYet(_ line: LocalizedStringKey) -> some View {
        ContentUnavailableView {
            Label {
                Text("No Text Yet")
            } icon: {
                tinted("text.alignleft")
            }
        } description: {
            Text(line)
        }
    }

    private func tinted(_ symbol: String) -> some View {
        Image(systemName: symbol).foregroundStyle(.tint)
    }
}
