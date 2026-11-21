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
    /// An icon button offered for a stage of a job, keeping one title, symbol
    /// and action across the stages that show it.
    enum Control: Hashable {
        case pause
        case resume
        case stop
        case cancelDownload

        var title: LocalizedStringKey {
            switch self {
            case .pause: "Pause Transcription"
            case .resume: "Resume Transcription"
            case .stop: "Stop Transcription"
            case .cancelDownload: "Cancel Download"
            }
        }

        var symbol: String {
            switch self {
            case .pause: "pause.circle.fill"
            case .resume: "play.circle.fill"
            case .stop: "stop.circle.fill"
            case .cancelDownload: "xmark.circle.fill"
            }
        }

        func perform(on model: AppModel) {
            switch self {
            case .pause: model.pause()
            case .resume: model.resume()
            case .stop, .cancelDownload: model.cancel()
            }
        }
    }

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

    static func controls(for stage: AppModel.Stage) -> [Control] {
        switch stage {
        case .transcribing: [.pause, .stop]
        case .paused: [.resume, .stop]
        case .downloading: [.cancelDownload]
        case .stopping, .waiting: []
        case .loading, .decoding, .repairing: [.stop]
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.stage {
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
        default: Image(systemName: "waveform").foregroundStyle(.tint)
        }
    }

    private var controls: some View {
        ForEach(Self.controls(for: model.stage), id: \.self) { item in
            Button {
                item.perform(on: model)
            } label: {
                Label(item.title, systemImage: item.symbol).labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .imageScale(.large)
            .help(item.title)
        }
    }
}

private func previewModel(in folder: URL, stage: AppModel.Stage) -> AppModel {
    let model = AppModel(
        history: folder.appending(path: "History"),
        glossaries: folder.appending(path: "Glossaries"),
        models: folder.appending(path: "Models"),
        playbackCopies: folder.appending(path: "Replay"),
        defaults: MemoryDefaults())
    model.stage = stage
    return model
}

private func previewEntry(in folder: URL, state: Entry.State) -> Entry {
    var entry = Entry(
        recording: folder.appending(path: "Lecture.wav"),
        modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
        subtitles: false)
    entry.publish([Segment(start: 0, end: 12, text: "Good morning everyone.")], partial: true)
    entry.state = state
    return entry
}

#Preview("Progress") {
    // Empty folders and settings of their own, never the user's.
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let idle = previewModel(in: folder, stage: .waiting)
    VStack(spacing: Spacing.block) {
        TranscriptionStatus(model: previewModel(in: folder, stage: .transcribing(0.42)))
        TranscriptionStatus(model: previewModel(in: folder, stage: .paused(0.42)))
        TranscriptionStatus(model: previewModel(in: folder, stage: .downloading(0.65)))
        EntryProgress(
            model: idle, entry: previewEntry(in: folder, state: .stopped), isRunning: false)
        EntryProgress(
            model: idle,
            entry: previewEntry(in: folder, state: .failed("The recording could not be read.")),
            isRunning: false)
    }
    .padding(Spacing.sheet)
}
