// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import whisper

/// The silence detector, which runs on a queue of its own.
nonisolated extension WhisperEngine {
    /// The stretches of speech the detector hears, in seconds. Asked of the
    /// detector rather than read from the context, which keeps the previous
    /// recording's stretches when it finds none (`whisper_vad`, v1.9.4).
    ///
    /// An empty result means it heard no speech. A detector that cannot run
    /// throws instead of reporting silence, since silence would wrongly claim
    /// the whole recording was left out of the transcript.
    static func speech(in samples: [Float], settings: DecodingSettings) async throws
        -> [ClosedRange<TimeInterval>]
    {
        // The detector has no abort callback, so a stop is honoured before it starts.
        try Task.checkCancellation()
        return try await detectingQueue.run { try detectSpeech(samples, settings) }
    }

    private static let detectingQueue = DispatchQueue(
        label: "io.github.miravassor.Polycop.detector", qos: .userInitiated)

    private static func detectSpeech(_ samples: [Float], _ settings: DecodingSettings)
        throws -> [ClosedRange<TimeInterval>]
    {
        // One thread: the detector reads the audio in small steps, each
        // waiting on the last, so more threads mostly spin while they wait,
        // which costs most when other work holds the cores. The stretches
        // found are the same.
        var context = whisper_vad_default_context_params()
        context.n_threads = 1
        guard let model = settings.voiceActivityModel,
            let detector = whisper_vad_init_from_file_with_params(
                model.path(percentEncoded: false), context)
        else {
            Log.transcription.error("the silence detector could not be opened")
            throw TranscriptionError.detectorUnavailable
        }
        defer { whisper_vad_free(detector) }

        var parameters = whisper_vad_default_params()
        parameters.threshold = settings.voiceActivityThreshold
        guard
            let found = samples.withUnsafeBufferPointer({
                whisper_vad_segments_from_samples(
                    detector, parameters, $0.baseAddress, Int32($0.count))
            })
        else {
            Log.transcription.error("the silence detector failed on this recording")
            throw TranscriptionError.detectorUnavailable
        }
        defer { whisper_vad_free_segments(found) }

        // Counted in hundredths of a second, like segment times. The model also
        // hears `samples_overlap` past each stretch but the last, which
        // whisper.cpp adds when joining them.
        let count = whisper_vad_segments_n_segments(found)
        let overlap = TimeInterval(parameters.samples_overlap)
        return (0..<count).map { index in
            let start = TimeInterval(whisper_vad_segments_get_segment_t0(found, index)) / 100
            let end = TimeInterval(whisper_vad_segments_get_segment_t1(found, index)) / 100
            return start...max(start, end + (index < count - 1 ? overlap : 0))
        }
    }
}
