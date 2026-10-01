// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the queue asks of a loaded model, whichever library runs it.
///
/// Each engine keeps its native state on a serial queue of its own and is
/// shared across tasks through that queue.
nonisolated protocol TranscriptionEngine: AnyObject, Sendable {
    /// Transcribes 16 kHz mono samples from `start`, reporting the fraction of
    /// that part done and each segment as it is decoded. Cancelling the task
    /// stops the computation.
    func transcribe(
        samples: [Float],
        settings: DecodingSettings,
        from start: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void,
        onSegment: @escaping @Sendable (Segment) -> Void
    ) async throws -> [Segment]

    /// Returns once every call already queued has ended and let go of the
    /// engine, so that releasing the caller's reference frees it at once.
    func drain() async

    /// How many tokens the model reads for a glossary given as a prompt,
    /// counted by its own tokenizer; nil for an engine that reads none.
    func promptTokenCount(of prompt: String) async -> Int?
}

nonisolated extension TranscriptionEngine {
    func promptTokenCount(of prompt: String) async -> Int? { nil }

    static func firstSample(at start: TimeInterval, count: Int) throws -> Int {
        guard start.isFinite else { throw TranscriptionError.invalidStart }
        return Int(min(Double(count), max(0, start * Double(AudioDecoder.sampleRate))))
    }

    /// The two refusals that need nothing but the file's name and the
    /// catalogue, a model that is not there, and one this Mac cannot hold.
    /// They come before any reading, since proving the contents of a model
    /// this Mac cannot run would be wasted time.
    static func refuse(_ model: URL, _ catalogued: Model?) throws {
        guard FileManager.default.fileExists(atPath: model.path(percentEncoded: false)) else {
            throw TranscriptionError.modelMissing(model)
        }
        if let catalogued, !Memory.isLikelyToFit(catalogued) {
            throw TranscriptionError.notEnoughMemory(
                needed: catalogued.peakBytes, budget: Memory.recommendedBudget)
        }
    }
}

/// One passage of the transcript, between two times of the recording.
nonisolated struct Segment: Equatable, Codable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Who speaks, for a model that tells speakers apart, written as "S01",
    /// "S02" the way MOSS writes them, numbered afresh in each window it reads.
    var speaker: String? = nil
    /// Each word with its times, for an engine that times words. Nil in records
    /// written before words were kept.
    var words: [Word]? = nil

    nonisolated struct Word: Equatable, Codable, Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        /// From 0 to 1, for an engine that reports how sure it was.
        var confidence: Float? = nil
    }

    func shifted(by offset: TimeInterval) -> Segment {
        guard offset != 0 else { return self }
        return Segment(
            start: start + offset, end: end + offset, text: text, speaker: speaker,
            words: words?.map {
                Word(
                    text: $0.text, start: $0.start + offset, end: $0.end + offset,
                    confidence: $0.confidence)
            })
    }

    /// The words no longer match a new text, so they are dropped.
    func replacing(text: String) -> Segment {
        Segment(start: start, end: end, text: text, speaker: speaker)
    }
}

nonisolated enum TranscriptionError: LocalizedError {
    case modelMissing(URL)
    case notEnoughMemory(needed: Int64, budget: Int64)
    case modelUnreadable(URL)
    case detectorUnavailable
    case failed(Int32)
    case invalidStart

    var errorDescription: String? {
        switch self {
        case .modelMissing(let model):
            return String(localized: "The model file is missing: \(model.lastPathComponent)")

        case .notEnoughMemory(let needed, let budget):
            return String(
                localized:
                    "This model needs about \(Memory.describe(needed)) at its peak, above the \(Memory.describe(budget)) this Mac recommends. Choose a lighter model."
            )

        case .modelUnreadable(let model):
            return String(
                localized:
                    "\(model.lastPathComponent) could not be opened. The file may be damaged, or this Mac may not have the memory for it."
            )

        case .detectorUnavailable:
            return String(
                localized:
                    "The silence detector could not be started. Turn off Skip silences in the advanced settings and transcribe again."
            )

        case .invalidStart:
            return String(localized: "The transcription start time is invalid.")

        case .failed(let code):
            return String(localized: "Transcription failed (code \(code)).")
        }
    }
}
