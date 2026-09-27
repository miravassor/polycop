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

    /// Finds the words in `text` by aligning both, as a diff does, rather than
    /// searching word by word, which let a short word such as "de" match far
    /// ahead and pull the rest of the paragraph out of place. Words are compared
    /// by their runs of letters and digits, lowercased, as `TimedWords` matches
    /// them, since an aligner splits "L'encodage" into "L" and "encodage" and
    /// drops punctuation.
    static func place(_ words: [Segment.Word], in text: String) -> [Placed] {
        let written = runs(in: text)
        let spoken = words.indices.flatMap { word in
            runs(in: words[word].text).map { (key: $0.key, word: word) }
        }
        var placed: [Placed] = []
        var last: (word: Int, run: Int)?
        for (heard, found) in Edits.pairs(spoken.map(\.key), written.map(\.key)) {
            let word = spoken[heard].word
            if let last, last.word == word {
                // A word of several runs spans those found side by side.
                guard last.run == found - 1, let previous = placed.popLast() else { continue }
                placed.append(
                    Placed(
                        range: NSUnionRange(previous.range, written[found].range),
                        start: previous.start, confidence: previous.confidence))
            } else {
                placed.append(
                    Placed(
                        range: written[found].range, start: words[word].start,
                        confidence: words[word].confidence))
            }
            last = (word, found)
        }
        return placed
    }

    /// The runs of letters and digits in `text`, lowercased, with their ranges.
    private static func runs(in text: String) -> [(key: String, range: NSRange)] {
        var runs: [(key: String, range: NSRange)] = []
        var start: (index: String.Index, offset: Int)?
        var offset = 0
        func close(at end: String.Index) {
            guard let first = start else { return }
            runs.append(
                (
                    text[first.index..<end].lowercased(),
                    NSRange(location: first.offset, length: offset - first.offset)
                ))
            start = nil
        }
        for index in text.indices {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = (index, offset) }
            } else {
                close(at: index)
            }
            offset += character.utf16.count
        }
        close(at: text.endIndex)
        return runs
    }

    /// The word being played at `position`.
    static func playing(_ placed: [Placed], at position: TimeInterval) -> NSRange? {
        placed.last { $0.start <= position }?.range
    }
}
