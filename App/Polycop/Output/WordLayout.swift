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
        var written: [(key: String, range: NSRange)] = []
        runs(in: text) { written.append(($0, $1)) }
        var spoken: [(key: String, word: Int)] = []
        for (index, word) in words.enumerated() {
            runs(in: word.text) { key, _ in spoken.append((key, index)) }
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

    /// Visits each run of letters and digits in `text`, lowercased, with its
    /// range. Scalars are read rather than characters, which is faster; an
    /// accent written apart is a mark, and stays in the run of its letter.
    private static func runs(in text: String, _ visit: (String, NSRange) -> Void) {
        let letters = CharacterSet.alphanumerics
        let scalars = text.unicodeScalars
        var start: (index: String.Index, offset: Int)?
        var offset = 0
        func close(at end: String.Index) {
            guard let first = start else { return }
            visit(
                text[first.index..<end].lowercased(),
                NSRange(location: first.offset, length: offset - first.offset))
            start = nil
        }
        for index in scalars.indices {
            let scalar = scalars[index]
            if letters.contains(scalar) {
                if start == nil { start = (index, offset) }
            } else {
                close(at: index)
            }
            offset += scalar.utf16.count
        }
        close(at: scalars.endIndex)
    }

    /// The index in `placedIn`, the text the words were placed in, of the
    /// character at `index` in `current`: typing not handed over yet changed
    /// one stretch of the text and moved what follows it.
    static func index(_ index: Int, in current: String, placedIn: String) -> Int {
        let current = current as NSString
        let unchanged = (current.commonPrefix(with: placedIn) as NSString).length
        guard index > unchanged else { return index }
        return max(unchanged, index - (current.length - (placedIn as NSString).length))
    }

    /// Where a click at `index` plays from: the start of the word clicked, or,
    /// in text written since, a time between the words still found around it,
    /// in proportion to where the click falls. `start`, the paragraph's opening
    /// second, stands before the first word.
    static func time(at index: Int, in placed: [Placed], from start: TimeInterval) -> TimeInterval {
        if let word = placed.first(where: {
            index >= $0.range.location && index <= NSMaxRange($0.range)
        }) {
            return word.start
        }
        let before = placed.last { NSMaxRange($0.range) < index }
        let location = before.map { NSMaxRange($0.range) } ?? 0
        let time = before?.start ?? start
        guard let after = placed.first(where: { $0.range.location > index }),
            after.start > time
        else { return time }
        let share = Double(index - location) / Double(after.range.location - location)
        return time + (after.start - time) * share
    }

    /// The word being played at `position`.
    static func playing(_ placed: [Placed], at position: TimeInterval) -> NSRange? {
        placed.last { $0.start <= position }?.range
    }
}
