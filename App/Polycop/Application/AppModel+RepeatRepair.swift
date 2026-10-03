// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: Repeat repair

extension AppModel {
    /// Whether the repeats of this transcript can be transcribed again. The
    /// repair needs silence removal, which only the entry's own engine
    /// supports, and paragraphs that can be rebuilt.
    func canRepairRepeats(of entry: Entry) -> Bool {
        canRebuildParagraphs(of: entry) && !entry.repeats.isEmpty
            && (ModelCatalog.model(entry.modelFile)?.engine.skipsSilence ?? false)
    }

    /// Transcribes again the stretches where one phrase repeats, with silence
    /// removal, which clears repetition loops. The rest of the transcript is
    /// left exactly as it is.
    func repairRepeats(_ id: Entry.ID) {
        guard !isShuttingDown, !stage.isBusy, busyEntry == nil, let entry = entry(id),
            canRepairRepeats(of: entry)
        else { return }
        failure = nil
        if entryFailure?.id == id { entryFailure = nil }
        // The entry keeps its state throughout, since a stop, a failure or
        // quitting loses only the repair; the transcript itself is untouched.
        // A transcript stopped part way stays stopped once repaired.
        repairing = id
        stage = .decoding
        repair(id)
    }

    /// One call per looped stretch, over that stretch only. Uses silence
    /// removal, which is what breaks the loop; whisper.cpp maps the reported
    /// times back onto the recording. What the detector left out of a
    /// replaced stretch is recorded, so the transcript says how much it was.
    private func repair(_ id: Entry.ID) {
        let number = beginJob()
        guard let entry = entry(id) else {
            finish()
            return
        }
        let segments = entry.decoded
        let ranges = entry.repeats
        let recording = recording(of: entry)
        let catalogued = ModelCatalog.model(entry.modelFile)
        var settings = DecodingSettings()
        settings.voiceActivityDetection = true
        settings.prompt = entry.prompt
        settings.language = entry.language ?? settings.language

        work = Task { [weak self] in
            guard let self else { return }
            do {
                guard let catalogued else { throw ModelStore.ImportError.unrecognized }
                let samples = try await AudioDecoder.samples(of: recording)
                try Task.checkCancellation()
                guard isCurrent(number) else { return }
                // Only an engine that skips silences is offered a repair
                // (`canRepairRepeats`), Whisper's today.
                let engine = try await preparedEngine(for: catalogued, skipsSilence: true)
                try Task.checkCancellation()
                guard isCurrent(number) else { return }

                await limitContextToGlossary(&settings, of: id, on: engine)
                // A stop during that wait has already set the stage.
                try Task.checkCancellation()
                guard isCurrent(number) else { return }
                var repaired = segments
                var speech = entry.speech
                let duration =
                    entry.duration ?? Double(samples.count) / Double(AudioDecoder.sampleRate)
                stage = .repairing(0)
                // From the end, so the ranges still ahead keep their indices.
                for (done, range) in ranges.reversed().enumerated() {
                    let from = segments[range.lowerBound].start
                    let to = segments[range.upperBound].end
                    let rate = Double(AudioDecoder.sampleRate)
                    let firstSample = max(0, min(samples.count, Int(from * rate)))
                    let lastSample = min(samples.count, Int(to * rate))
                    guard firstSample < lastSample else { continue }
                    let again = try await Self.transcribe(
                        Array(samples[firstSample..<lastSample]), from: from, on: engine,
                        settings: settings)
                    try Task.checkCancellation()
                    guard isCurrent(number) else { return }
                    guard let again else { continue }
                    repaired.replaceSubrange(range, with: again.segments)
                    speech = Entry.speech(
                        speech, duration: duration, replacing: from...to, with: again.kept)
                    stage = .repairing(Double(done + 1) / Double(ranges.count))
                }
                undoSteps[id] = nil
                updateEntry(id) {
                    $0.publish(repaired, partial: entry.isPartial)
                    $0.speech = speech
                    $0.duration = $0.duration ?? duration
                }
                finish()
            } catch is CancellationError {
                guard isCurrent(number) else { return }
                pausing = false
                // Only the repair is lost. The transcript stays intact either way.
                finish()
            } catch {
                guard isCurrent(number) else { return }
                pausing = false
                Log.transcription.error(
                    "transcribing the repeats failed: \(error, privacy: .private)")
                // The failure belongs to this transcript, not the library,
                // since the list may have moved on before the work ended.
                entryFailure = EntryFailure(id: id, message: error.localizedDescription)
                finish()
            }
        }
    }

    /// A looped stretch transcribed again, and the stretches its silence
    /// detector kept, both in recording time. Nil when no text came out, in
    /// which case the stretch stays as it was.
    nonisolated private static func transcribe(
        _ slice: [Float], from: TimeInterval, on engine: any TranscriptionEngine,
        settings: DecodingSettings
    ) async throws -> (segments: [Segment], kept: [ClosedRange<TimeInterval>])? {
        let again = try await engine.transcribe(
            samples: slice, settings: settings, from: 0, onProgress: { _ in }, onSegment: { _ in })
        guard
            again.contains(where: {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else { return nil }
        let kept = try await WhisperEngine.speech(in: slice, settings: settings)
        return (
            again.map { $0.shifted(by: from) },
            kept.map { ($0.lowerBound + from)...($0.upperBound + from) }
        )
    }
}
