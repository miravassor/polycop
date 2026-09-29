// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How audio.cpp runs one model family, set from its official implementation.
nonisolated struct AudioCppProfile: Sendable {
    /// How the audio reaches the model and the text comes back.
    enum Feed: Sendable {
        /// One offline call per window.
        case whole
        /// The whole window given at once, the text read token by token, so a
        /// stop lands between two tokens. MOSS returns the same text this way
        /// as offline (`TranscribeRuntime::transcribe`, v0.8.1).
        case text
        /// The audio pushed as it would arrive live, the text read as it
        /// comes, the way Voxtral Realtime is meant to run, with a rolling
        /// cache.
        case audio
    }

    /// The loader's name in audio.cpp.
    let family: String
    /// The longest piece of audio given to one call.
    let window: TimeInterval
    /// Whether a window ends at the quietest point near its length rather
    /// than exactly at it.
    let cutsAtSilence: Bool
    let feed: Feed
    /// Qwen is told the language. The others detect it, and MOSS refuses an
    /// option it does not declare.
    let setsLanguage: Bool
    /// MOSS reads the glossary as hotwords appended to its own instruction.
    let readsHotwords: Bool
    /// Request options. Each limit only stops a looping window.
    let options: KeyValuePairs<String, String>

    /// With audio streamed, text is gathered into segments of this length.
    static let streamedSegment: TimeInterval = 30

    /// How far apart the segments of a family that does not time sentences
    /// begin.
    var timestampSpacing: TimeInterval { feed == .audio ? Self.streamedSegment : window }

    /// Windows of 30 seconds, cut exactly, as audio.cpp's own offline path
    /// cuts them. audio.cpp refuses windows of 120 seconds
    /// (`max_source_positions`), where the official toolkit takes 20 minutes.
    static let qwen = AudioCppProfile(
        family: "qwen3_asr", window: 30, cutsAtSilence: false, feed: .whole, setsLanguage: true,
        readsHotwords: false,
        options: ["audio_chunk_mode": "none", "max_tokens": "1024"])
    /// Five minutes per window. audio.cpp
    /// reserves the cache for every token allowed, so the official 65536 for
    /// long audio would hold gigabytes for nothing.
    static let moss = AudioCppProfile(
        family: "moss_transcribe_diarize", window: 300, cutsAtSilence: true, feed: .text,
        setsLanguage: false,
        readsHotwords: true, options: ["max_tokens": "8192"])
    /// Streamed, as Voxtral Realtime is meant to run, word for word what
    /// audiocpp_cli streams.
    static let voxtral = AudioCppProfile(
        family: "voxtral_realtime", window: 300, cutsAtSilence: true, feed: .audio,
        setsLanguage: false, readsHotwords: false, options: [:])
}
