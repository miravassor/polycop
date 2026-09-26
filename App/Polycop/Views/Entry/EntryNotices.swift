// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Warnings about the recording, the output or a background failure. Shown
/// above the transcript text.
struct EntryNotices: View {
    let entry: Entry
    let model: AppModel
    let isRunning: Bool
    let engine: Engine?

    var body: some View {
        if let warning = entry.glossaryWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        if let warning = entry.repetitionWarning {
            HStack(spacing: 12) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                if !entry.repeats.isEmpty, engine?.skipsSilence == true {
                    Button("Transcribe the Repeats Again") { model.repairRepeats(entry.id) }
                        .disabled(
                            isRunning || !model.canRepairRepeats(of: entry) || model.stage.isBusy
                        )
                        .help(
                            !model.hasOnlyCourseCorrections(entry)
                                ? Text("Transcribing them again would undo your corrections.")
                                : Text("Skips the silences over those passages only.")
                        )
                }
            }
        }
        if let times = entry.resumedAt, !times.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "Resumed after a pause. Words near these points can be missing or repeated:",
                    systemImage: "arrow.clockwise"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(times.enumerated()), id: \.offset) { _, time in
                            Button(Transcript.clock(Int(time * 1000))) {
                                model.replay(entry.id, from: max(0, time - 10))
                            }
                            .buttonStyle(.plain)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.tint)
                            .help("Listen from ten seconds before")
                        }
                    }
                }
            }
        }
        if !entry.hasRecording {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Label("Recording unavailable", systemImage: "questionmark.folder")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    Button("Locate Recording…") { locateRecording() }
                        .disabled(isRunning)
                }
                Text(
                    "The transcript is safe. Listening, transcribing again and repairing the repeats all need the original recording."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(entry.location.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        if let leftOut = entry.leftOut, let duration = entry.duration {
            Label(
                "Skip silences left \(formattedDuration(leftOut)) of this \(formattedDuration(duration)) recording out of the transcript. Some of it may have been speech.",
                systemImage: "waveform"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        }
        ForEach(
            [Credits.notice(entry.hiddenCredits), Degeneration.loopNotice(entry.shortenedLoops)]
                .compactMap { $0 },
            id: \.self
        ) { notice in
            HStack(spacing: 12) {
                Label(notice, systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Button("Put back") { model.putBackCredits(entry.id) }
                    .disabled(!model.canPutBackCredits(of: entry))
                    .help(
                        !model.hasOnlyCourseCorrections(entry) || model.canUndo(entry.id)
                            ? Text("Putting the lines back would undo your corrections.") : Text("")
                    )
            }
        }
        ForEach(
            [model.failure, model.failure(for: entry.id), model.player.failure].compactMap { $0 },
            id: \.self
        ) { failure in
            Label(failure, systemImage: "xmark.octagon")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    /// Where the recording went. Nothing is transcribed again: the transcript
    /// only needs its audio back to be listened to.
    private func locateRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose the recording this transcript was made from.")
        panel.directoryURL = entry.location.deletingLastPathComponent()
        guard panel.runModal() == .OK, let found = panel.url else { return }
        model.locateRecording(entry.id, at: found)
    }
}
