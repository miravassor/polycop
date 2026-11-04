// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: Importing a transcript made elsewhere

extension AppModel {
    func chooseTranscriptImport() {
        guard !isShuttingDown, !stage.isBusy else { return }
        transcriptImportRequest = UUID()
    }

    /// Adds a transcript made elsewhere, with its recording, and opens it.
    /// Returns once the import has ended, so the sheet that asked closes or
    /// says why: a failure is thrown to it rather than shown on the page
    /// behind. A stop adds nothing.
    func importTranscript(_ transcript: URL, audio: URL) async throws {
        guard !isShuttingDown, !stage.isBusy else { return }
        failure = nil
        stage = .decoding
        let number = beginJob()
        let reading = Task {
            let parsed = try await TranscriptImport.read(transcript)
            let duration =
                Double(try await AudioDecoder.samples(of: audio).count)
                / Double(AudioDecoder.sampleRate)
            try Task.checkCancellation()
            return try parsed.entry(
                recording: audio, duration: duration, source: transcript.lastPathComponent)
        }
        // The job's handle, which a stop cancels and quitting waits for.
        work = Task {
            await withTaskCancellationHandler {
                _ = await reading.result
            } onCancel: {
                reading.cancel()
            }
        }
        defer { if isCurrent(number) { finish() } }
        var entry: Entry
        do {
            entry = try await reading.value
        } catch is CancellationError {
            return
        }
        guard isCurrent(number) else { return }
        entry = adoptingLastExport(entry)
        let names = Set(entries.map(\.name))
        if names.contains(entry.name) {
            entry.title = Entry.freeName(from: entry.name, of: entry.recording, among: names)
        }
        entries.insert(entry, at: 0)
        store(entry)
        pane = .entry(entry.id)
    }
}
