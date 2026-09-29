// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Matches transcript sentences to word timestamps without changing their text.
nonisolated enum TimedWords {
    typealias Word = Segment.Word

    /// Matches letters and digits despite differences in word boundaries or punctuation.
    /// Returns nil on a mismatch rather than assigning unsupported sentence times.
    static func sentences(of text: String, timedBy words: [Word]) -> [Segment]? {
        func spelling(_ string: some StringProtocol) -> String {
            String(string.filter { $0.isLetter || $0.isNumber }).lowercased()
        }
        func letters(_ string: some StringProtocol) -> Int { spelling(string).count }
        guard !words.isEmpty, spelling(text) == words.map({ spelling($0.text) }).joined() else {
            return nil
        }
        // A sentence ends on a word that ends with its punctuation, so that
        // "etc.," or "3.5" stay whole.
        var sentences: [String] = []
        var current: [Substring] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            current.append(word)
            if let last = word.last, ".!?…".contains(last) {
                sentences.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { sentences.append(current.joined(separator: " ")) }

        var segments: [Segment] = []
        var next = 0
        for sentence in sentences {
            var needed = letters(sentence)
            guard needed > 0 else {
                // Punctuation alone belongs to the sentence before it.
                guard let last = segments.popLast() else { return nil }
                segments.append(
                    Segment(
                        start: last.start, end: last.end, text: last.text + " " + sentence,
                        words: last.words))
                continue
            }
            let first = next
            while needed > 0, next < words.count {
                needed -= letters(words[next].text)
                next += 1
            }
            guard needed == 0 else { return nil }
            segments.append(
                Segment(
                    start: words[first].start, end: words[next - 1].end, text: sentence,
                    words: Array(words[first..<next])))
        }
        return segments
    }
}
