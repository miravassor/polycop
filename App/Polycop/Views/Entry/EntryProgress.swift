// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What is happening to this transcript. The work in progress is read from
/// the model rather than the entry. Repairing the repeats of a finished
/// transcript leaves it finished throughout, since its text stays complete.
struct EntryProgress: View {
    let model: AppModel
    let entry: Entry
    let isRunning: Bool

    var body: some View {
        if isRunning {
            progress
        } else {
            switch entry.state {
            case .waiting, .running:
                waiting
            case .finished:
                EmptyView()
            case .stopped:
                HStack(spacing: 12) {
                    Label("Stopped before the end", systemImage: "stop.circle")
                        .foregroundStyle(.orange)
                    retry
                }
            case .failed(let message):
                HStack(spacing: 12) {
                    Label(message, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    retry
                }
            }
        }
    }

    /// A retry repeats the job this recording was given, not the settings that
    /// happen to be on the New Transcription page now.
    private var retry: some View {
        Button("Retry") { model.retry(entry.id) }
            .help("Transcribe the recording again with the settings it was given")
    }

    /// Waiting for its turn, or for the model it needs. A transfer that was
    /// cancelled or failed leaves the recording here instead of marking it
    /// failed, since only the model is missing, not the recording.
    @ViewBuilder
    private var waiting: some View {
        if case .downloading(let fraction) = model.stage,
            model.downloadingModel?.id == entry.modelFile
        {
            HStack(spacing: 12) {
                running("Downloading the model", fraction)
                Button("Cancel") { model.cancel() }
                Spacer()
            }
            .frame(height: 34)
        } else if model.canStart {
            HStack(spacing: 12) {
                Button(model.isScheduled(entry.id) ? "Continue Transcription" : "Review Settings") {
                    if model.isScheduled(entry.id) {
                        model.continueQueue()
                    } else {
                        model.pane = .new
                    }
                }
                .buttonStyle(.borderedProminent)
                Text(startingNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Waiting for its turn")
                .foregroundStyle(.secondary)
        }
    }

    private var startingNote: LocalizedStringKey {
        if let wanted = model.missingModel {
            return "\(wanted.name) is downloaded first."
        }
        let waiting = model.waiting.count
        return waiting > 1
            ? "Transcribes the \(waiting) recordings waiting, in turn."
            : "One recording at a time, in the order you added them."
    }

    /// One shape for every step of the job, so the page reads the same way
    /// whichever step is under way.
    private var progress: some View {
        HStack(spacing: 12) {
            switch model.stage {
            case .decoding:
                running("Converting the audio", nil)
            case .loading:
                running("Loading the model", nil)
            case .transcribing(let fraction):
                running("Transcribing", fraction)
                Button("Pause") { model.pause() }
            case .repairing(let fraction):
                running("Transcribing the repeats", fraction)
            case .paused(let fraction):
                Text("Paused")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ProgressView(value: fraction)
                    .frame(minWidth: 60, maxWidth: 180)
                Text(percent(fraction))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Resume") { model.resume() }
            case .stopping:
                Text("Stopping")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            case .waiting, .downloading:
                EmptyView()
            }
            if model.stage != .stopping {
                Button("Cancel") { model.cancel() }
            }
            Spacer()
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private func running(_ title: LocalizedStringKey, _ fraction: Double?) -> some View {
        Text(title)
            .font(.headline)
        if let fraction {
            ProgressView(value: fraction)
                .frame(minWidth: 60, maxWidth: 180)
            Text(percent(fraction))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}
