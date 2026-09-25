// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: Repeat repair

extension AppModel {
    /// Whether the repeats of this transcript can be transcribed again. The
    /// repair needs silence removal, which only the entry's own engine
    /// supports, and text the user has not corrected.
    func canRepairRepeats(of entry: Entry) -> Bool {
        !entry.isEdited && !entry.repeats.isEmpty
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
        // The entry stays finished throughout, since a stop, a failure or
        // quitting loses only the repair; the transcript itself is untouched.
        repairing = id
        stage = .decoding
        repair(id)
    }

    /// One call per looped stretch, over that stretch only. Uses silence
    /// removal, which is what breaks the loop; whisper.cpp maps the reported
    /// times back onto the recording.
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
                let engine = try await preparedEngine(for: catalogued, skipsSilence: true)
                try Task.checkCancellation()
                guard isCurrent(number) else { return }
                // Only a Whisper transcript is offered a repair (`canRepairRepeats`).
                guard let whisper = engine as? WhisperEngine else {
                    throw ModelStore.ImportError.unrecognized
                }

                await limitContextToGlossary(&settings, of: id, on: whisper)
                var repaired = segments
                stage = .repairing(0)
                // From the end, so the ranges still ahead keep their indices.
                for (done, range) in ranges.reversed().enumerated() {
                    let from = segments[range.lowerBound].start
                    let to = segments[range.upperBound].end
                    let rate = Double(AudioDecoder.sampleRate)
                    let firstSample = max(0, min(samples.count, Int(from * rate)))
                    let lastSample = min(samples.count, Int(to * rate))
                    guard firstSample < lastSample else { continue }
                    let again = try await whisper.transcribe(
                        samples: Array(samples[firstSample..<lastSample]), settings: settings)
                    try Task.checkCancellation()
                    guard isCurrent(number) else { return }
                    guard
                        again.contains(where: {
                            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        })
                    else { continue }
                    repaired.replaceSubrange(range, with: again.map { $0.shifted(by: from) })
                    stage = .repairing(Double(done + 1) / Double(ranges.count))
                }
                corrections[id] = nil
                updateEntry(id) {
                    $0.publish(repaired, partial: entry.isPartial)
                    $0.state = .finished
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
}
