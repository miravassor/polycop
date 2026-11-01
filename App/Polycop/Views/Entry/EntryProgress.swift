// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What is happening to this transcript, above its text: the work under way
/// in a capsule, or how it ended when it ended early. A page without text says
/// the rest in its empty state. The work is read from the model rather than
/// the entry. Repairing the repeats of a finished transcript leaves it
/// finished throughout, since its text stays complete.
struct EntryProgress: View {
    let model: AppModel
    let entry: Entry
    let isRunning: Bool

    var body: some View {
        if isRunning || model.isWaitingForDownload(entry) {
            TranscriptionStatus(model: model)
        } else if !entry.paragraphs.isEmpty {
            switch entry.state {
            case .stopped:
                HStack(spacing: 12) {
                    Label("Stopped before the end", systemImage: "stop.circle")
                        .notice(.orange)
                    retry
                }
            case .failed(let message):
                HStack(spacing: 12) {
                    Label(message, systemImage: "xmark.octagon")
                        .notice(.red)
                        .textSelection(.enabled)
                    retry
                }
            case .waiting, .running, .finished:
                EmptyView()
            }
        }
    }

    private var retry: some View {
        Button("Retry") { model.retry(entry.id) }
            .help("Transcribe the recording again with the settings it was given")
    }
}

/// The work under way on one line, centred above the text on the player's
/// surface, as the player is below it: what runs, in the library's words, how
/// far, and the buttons that pause and stop it.
struct TranscriptionStatus: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(model.stage.title)
            } icon: {
                icon
            }
            .help(
                model.stage.isDownloading
                    ? "Transcription starts once it is downloaded"
                    : "The text can be edited once it stops")
            if let fraction = model.stage.fraction {
                ProgressView(value: fraction).frame(width: 180)
                Text(percent(fraction)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear).frame(width: 180)
            }
            controls
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(FloatingSurface(cornerRadius: 22))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var icon: some View {
        switch model.stage {
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
        default: Image(systemName: "waveform").foregroundStyle(.tint)
        }
    }

    /// Icon buttons, as the model download's row on New Transcription; the
    /// File menu has the same commands.
    @ViewBuilder private var controls: some View {
        Group {
            switch model.stage {
            case .transcribing:
                control("Pause Transcription", "pause.circle.fill", model.pause)
                control("Stop Transcription", "stop.circle.fill", model.cancel)
            case .paused:
                control("Resume Transcription", "play.circle.fill", model.resume)
                control("Stop Transcription", "stop.circle.fill", model.cancel)
            case .downloading:
                control("Cancel Download", "xmark.circle.fill", model.cancel)
            case .stopping, .waiting:
                EmptyView()
            case .loading, .decoding, .repairing:
                control("Stop Transcription", "stop.circle.fill", model.cancel)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .imageScale(.large)
    }

    private func control(
        _ title: LocalizedStringKey, _ symbol: String, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .accessibilityLabel(title)
            .help(title)
    }
}
