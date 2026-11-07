// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Every whisper.cpp parameter the app sets, in one place.
///
/// The values are those of `whisper-cli`. Only the model and the silence
/// detection were chosen by measurement; nothing else here departs from the
/// library.
nonisolated struct DecodingSettings: Equatable, Sendable {
    /// Language of the recording, or `automaticLanguage`.
    var language = "fr"

    /// The model detects the language. This is the word whisper.cpp takes for it
    /// (`whisper_full_with_state`, v1.9.4): it decides once, from the first 30
    /// seconds it is given. Qwen is told nothing, and decides for each window.
    static let automaticLanguage = "auto"

    /// What the window offers beside automatic. These are the languages on
    /// Voxtral's model card, the shortest list of the models, and each was tried
    /// on Whisper, Qwen and MOSS.
    /// A code is Whisper's, and a name is the word Qwen is told.
    static let languages: [(code: String, name: String)] = [
        ("ar", "Arabic"), ("zh", "Chinese"), ("nl", "Dutch"), ("en", "English"),
        ("fr", "French"), ("de", "German"), ("hi", "Hindi"), ("it", "Italian"),
        ("ja", "Japanese"), ("ko", "Korean"), ("pt", "Portuguese"), ("ru", "Russian"),
        ("es", "Spanish"),
    ]

    static func offers(_ code: String) -> Bool {
        code == automaticLanguage || languages.contains { $0.code == code }
    }

    /// Beam search width, and the candidates kept when a window is decoded
    /// again at a higher temperature. Both are live. Under beam search
    /// whisper.cpp allocates `max(best_of, beam_size)` decoders and uses
    /// `best_of` above temperature zero (`whisper_full_with_state`, v1.9.4).
    var beamSize: Int32 = 5
    var bestOf: Int32 = 5

    /// Decoding starts without randomness and only becomes random when a
    /// window fails the thresholds below.
    var temperature: Float = 0
    var temperatureIncrement: Float = 0.2
    var entropyThreshold: Float = 2.4
    var logProbabilityThreshold: Float = -1
    var noSpeechThreshold: Float = 0.6

    /// The performance cores, asked of the machine rather than assumed. It
    /// changes little, since most of the work runs on the GPU. `whisper-cli`
    /// uses `min(4, hardware_concurrency)`.
    var threads = Int32(DecodingSettings.performanceCores)

    static var performanceCores: Int {
        var count = 0
        var size = MemoryLayout<Int>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return count
        }
        return min(4, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// The glossary sentence, prepended to every window so that a lecture of
    /// one hour keeps its vocabulary. Only the last 223 tokens are read.
    var prompt: String?

    /// How many tokens of earlier text a window reads, glossary included. The
    /// library default is capped by whisper.cpp at half the model's context,
    /// so it effectively means as many as fit. The app overrides it for every
    /// transcription, using zero without a glossary or the glossary's length
    /// plus one with one, since zero would drop the glossary too
    /// (`whisper_full_with_state`, v1.9.4).
    var textContext: Int32 = 16384

    /// Silence removal, off by default because it can discard genuine speech
    /// at a quiet volume. The threshold is lower than the library default of
    /// 0.5, which lost more speech than this one.
    var voiceActivityDetection = false
    var voiceActivityThreshold: Float = 0.25

    /// Shipped in the bundle, so silence removal works without a download.
    var voiceActivityModel = Bundle.main.url(
        forResource: "ggml-silero-v6.2.0", withExtension: "bin")
}
