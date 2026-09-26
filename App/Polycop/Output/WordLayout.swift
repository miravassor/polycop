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
    /// their start.
    static func grouped(
        _ segments: [Segment], into paragraphs: [Transcript.Paragraph]
    ) -> [[Segment.Word]] {
        var groups = Array(repeating: [Segment.Word](), count: paragraphs.count)
        guard !paragraphs.isEmpty else { return groups }
        let starts = paragraphs.map(\.seconds)
        for word in segments.flatMap({ $0.words ?? [] }) {
            let index = starts.lastIndex { $0 <= word.start + 0.001 } ?? 0
            groups[index].append(word)
        }
        return groups
    }

    /// Finds the words in `text` in order. A word corrected since, and so no
    /// longer found close to where it was, is left out.
    static func place(_ words: [Segment.Word], in text: String) -> [Placed] {
        let string = text as NSString
        var cursor = 0
        var placed: [Placed] = []
        for word in words {
            let length = (word.text as NSString).length
            guard length > 0, cursor < string.length else { continue }
            // A few words of slack, so a deleted word does not match much later.
            let window = NSRange(
                location: cursor, length: min(string.length - cursor, length + 40))
            let found = string.range(of: word.text, options: [], range: window)
            guard found.location != NSNotFound else { continue }
            placed.append(Placed(range: found, start: word.start, confidence: word.confidence))
            cursor = NSMaxRange(found)
        }
        return placed
    }

    /// The word being played at `position`.
    static func playing(_ placed: [Placed], at position: TimeInterval) -> NSRange? {
        placed.last { $0.start <= position }?.range
    }
}
