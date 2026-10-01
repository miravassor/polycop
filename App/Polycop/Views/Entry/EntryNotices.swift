// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Warnings about the recording, the output or a background failure. Shown
/// above the transcript text.
struct EntryNotices: View {
    let entry: Entry
    let findings: Entry.Findings
    let model: AppModel
    let isRunning: Bool
    let engine: Engine?

    var body: some View {
        // Asked once, and only when a notice offers to rebuild: the answer
        // runs the course corrections over the whole text.
        let offersRebuild =
            !findings.repeats.isEmpty || !findings.hiddenCredits.isEmpty
            || !findings.shortenedLoops.isEmpty
        let canRebuild = offersRebuild && model.canRebuildParagraphs(of: entry)
        if let warning = entry.glossaryWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .notice(.orange)
                .textSelection(.enabled)
        }
        if let warning = findings.repetitionWarning {
            HStack(spacing: 12) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .notice(.orange)
                    .textSelection(.enabled)
                // The repeats and the engine are checked here, so only the
                // corrections decide.
                if !findings.repeats.isEmpty, engine?.skipsSilence == true {
                    Button("Transcribe the Repeats Again") { model.repairRepeats(entry.id) }
                        .disabled(isRunning || !canRebuild || model.stage.isBusy)
                        .help(
                            !canRebuild
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
                .notice(.orange)
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
                        .notice(.orange)
                    Button("Locate Recording…") { locateRecording() }
                        .disabled(isRunning)
                }
                Text(
                    "The transcript is safe. Listening, transcribing again and repairing the repeats all need the original recording: locate it, or connect the disk it is on."
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
            .notice(.orange)
        }
        ForEach(
            [
                Credits.notice(findings.hiddenCredits),
                Degeneration.loopNotice(findings.shortenedLoops),
            ]
            .compactMap { $0 },
            id: \.self
        ) { notice in
            HStack(spacing: 12) {
                Label(notice, systemImage: "eye.slash")
                    .font(.callout)
                    .notice(.orange)
                    .textSelection(.enabled)
                Button("Put back") { model.putBackCredits(entry.id) }
                    .disabled(!canRebuild)
                    .help(
                        !canRebuild
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
                .notice(.red)
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
