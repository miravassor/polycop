// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import audiocpp

/// How Qwen3-ASR is asked and read: its whole window at once, timed in
/// sentences when the aligner runs.
nonisolated extension AudioCppEngine {
    /// Qwen names languages in English words where the app keeps codes.
    static let qwenLanguages = ["fr": "French", "en": "English"]

    /// Qwen's text as the sentences the aligner timed, placed on the
    /// recording; else one segment for the whole window.
    static func qwenSegments(of result: OpaquePointer?, in window: Range<Int>) throws
        -> [Segment]
    {
        let rate = Double(AudioDecoder.sampleRate)
        let offset = Double(window.lowerBound) / rate
        let length = Double(window.count) / rate
        func time(_ sample: Int64) -> TimeInterval {
            offset + min(max(0, Double(sample) / rate), length)
        }

        let words = try text(of: result).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        var aligned: [TimedWords.Word] = []
        for index in 0..<audiocpp_result_word_count(result) {
            var word: UnsafePointer<CChar>?
            var start: Int64 = 0
            var end: Int64 = 0
            try check(audiocpp_result_word(result, index, &word, &start, &end, nil))
            aligned.append(
                TimedWords.Word(
                    text: word.map { String(cString: $0) } ?? "", start: time(start),
                    end: max(time(start), time(end))))
        }
        return TimedWords.sentences(of: words, timedBy: aligned)
            ?? [Segment(start: offset, end: offset + length, text: words)]
    }
}
