// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where each timed word sits in the text of its paragraph.
nonisolated enum WordLayout {
    /// Below this confidence a word is marked as uncertain.
    static let uncertainty: Float = 0.5

    struct Placed: Equatable {
        let range: NSRange
        let start: TimeInterval
        let confidence: Float?

        var isUncertain: Bool { confidence.map { $0 < WordLayout.uncertainty } ?? false }
    }

    /// The words of `segments`, grouped by the paragraph whose time span holds
    /// their start. Words come in time order, so the paragraph only moves on.
    static func grouped(
        _ segments: [Segment], into paragraphs: [Transcript.Paragraph]
    ) -> [[Segment.Word]] {
        var groups = Array(repeating: [Segment.Word](), count: paragraphs.count)
        guard !paragraphs.isEmpty else { return groups }
        let starts = paragraphs.map(\.seconds)
        var index = 0
        for word in segments.lazy.flatMap({ $0.words ?? [] }) {
            while index + 1 < starts.count, starts[index + 1] <= word.start + 0.001 {
                index += 1
            }
            groups[index].append(word)
        }
        return groups
    }

    /// Finds the words in `text` in order. A word corrected since, and so no
    /// longer found close to where it was, is left out.
    static func place(_ words: [Segment.Word], in text: String) -> [Placed] {
        let string = text as NSString
        var cursor = 0
        // A few words of slack, so a deleted word does not match much later.
        // Each word not found doubles it, up to the whole text, so the search
        // catches up after an insertion or a rewrite.
        var slack = 40
        var placed: [Placed] = []
        for word in words {
            let length = (word.text as NSString).length
            guard length > 0, cursor < string.length else { continue }
            let window = NSRange(
                location: cursor, length: min(string.length - cursor, length + slack))
            guard let found = find(word.text, in: string, within: window) else {
                slack = min(slack * 2, string.length)
                continue
            }
            placed.append(Placed(range: found, start: word.start, confidence: word.confidence))
            cursor = NSMaxRange(found)
            slack = 40
        }
        return placed
    }

    /// The first time `word` stands as a word in `window`, so that "a" is not
    /// found inside "la".
    private static func find(_ word: String, in text: NSString, within window: NSRange) -> NSRange?
    {
        var searched = window
        while searched.length > 0 {
            let found = text.range(of: word, options: [], range: searched)
            guard found.location != NSNotFound else { return nil }
            if TranscriptSearch.isWholeWord(found, in: text) { return found }
            let next = NSMaxRange(found)
            searched = NSRange(location: next, length: NSMaxRange(window) - next)
        }
        return nil
    }

    /// The word being played at `position`.
    static func playing(_ placed: [Placed], at position: TimeInterval) -> NSRange? {
        placed.last { $0.start <= position }?.range
    }
}
