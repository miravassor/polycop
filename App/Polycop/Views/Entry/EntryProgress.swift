// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The job on this transcript, or how it ended if it stopped early. Read from
/// the model: a repair leaves the entry finished.
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
                    if !entry.decoded.isEmpty { resume }
                    retry
                }
                .statusCapsule()
            case .failed(let message):
                HStack(spacing: 12) {
                    Notice(message, .failure)
                        .textSelection(.enabled)
                    retry
                }
                .statusCapsule()
            case .waiting, .running, .finished:
                EmptyView()
            }
        }
    }

    private var resume: some View {
        Button("Resume Transcription") { model.resumeStopped(entry.id) }
            .disabled(!model.canResume(entry))
            .help("Continue from where it stopped, for a transcript with no corrections of yours")
    }

    private var retry: some View {
        Button("Retry") { model.retry(entry.id) }
            .help("Transcribe the recording again with the settings it was given")
    }
}

/// The running job's progress and controls, in a floating capsule.
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
        .statusCapsule()
    }

    @ViewBuilder private var icon: some View {
        switch model.stage {
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
        default: Image(systemName: "waveform").foregroundStyle(.tint)
        }
    }

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
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .help(title)
    }
}

#Preview("Progress") {
    // Empty folders and settings of their own, never the user's.
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let model = { (stage: AppModel.Stage) -> AppModel in
        let model = AppModel(
            history: folder.appending(path: "History"),
            glossaries: folder.appending(path: "Glossaries"),
            models: folder.appending(path: "Models"),
            playbackCopies: folder.appending(path: "Replay"),
            defaults: MemoryDefaults())
        model.keepAwake = false
        model.stage = stage
        return model
    }
    let entry = { (state: Entry.State) -> Entry in
        var entry = Entry(
            recording: folder.appending(path: "Lecture.wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        entry.publish([Segment(start: 0, end: 12, text: "Good morning everyone.")], partial: true)
        entry.state = state
        return entry
    }
    let idle = model(.waiting)
    VStack(spacing: Spacing.block) {
        TranscriptionStatus(model: model(.transcribing(0.42)))
        TranscriptionStatus(model: model(.paused(0.42)))
        TranscriptionStatus(model: model(.downloading(0.65)))
        EntryProgress(model: idle, entry: entry(.stopped), isRunning: false)
        EntryProgress(
            model: idle, entry: entry(.failed("The recording could not be read.")),
            isRunning: false)
    }
    .padding(Spacing.sheet)
}
