// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where each timed word sits in the text of its paragraph.
nonisolated enum WordLayout {
    /// Below this confidence a word is marked as uncertain.
    static let uncertainty: Float = 0.5
    /// Below this length, a stretch said but removed from the text, such as a
    /// hesitation left out, keeps the word before it lit rather than none.
    static let briefRemoval: TimeInterval = 1

    /// A timed word and where the text shows it: a word found, text written in
    /// place of words said, which has no confidence, or words said but removed,
    /// whose range is empty.
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
    ///
    /// Where words said are missing from the text, the text written in their
    /// place takes their time, spread over it, so the word lit goes on through
    /// a correction. Words said but removed get an empty range: while they are
    /// heard, no word is lit rather than the one before them.
    static func place(_ words: [Segment.Word], in text: String) -> [Placed] {
        var written: [(key: String, range: NSRange)] = []
        runs(in: text) { written.append(($0, $1)) }
        var spoken: [(key: String, word: Int)] = []
        for (index, word) in words.enumerated() {
            runs(in: word.text) { key, _ in spoken.append((key, index)) }
        }
        // Each word found, with the runs of the text it spans.
        var found: [(word: Int, runs: ClosedRange<Int>)] = []
        for (heard, run) in Edits.pairs(spoken.map(\.key), written.map(\.key)) {
            let word = spoken[heard].word
            guard let last = found.last, last.word == word else {
                found.append((word, run...run))
                continue
            }
            // A word of several runs spans those found side by side.
            if last.runs.upperBound == run - 1 {
                found[found.count - 1].runs = last.runs.lowerBound...run
            }
        }

        // Punctuation said alone, such as a word "?", has nothing to be missing.
        var said = [Bool](repeating: false, count: words.count)
        for run in spoken { said[run.word] = true }
        var placed: [Placed] = []
        var nextWord = 0
        var nextRun = 0
        func fill(before word: Int, run: Int, until end: TimeInterval) {
            let missing = (nextWord..<word).filter { said[$0] }
            guard let first = missing.first, let last = missing.last else { return }
            let start = words[first].start
            let replacing = written[nextRun..<run]
            guard !replacing.isEmpty else {
                // Measured on the words removed, not on the pause after them.
                guard words[last].end - start >= briefRemoval else { return }
                let after = placed.last.map { NSMaxRange($0.range) } ?? 0
                placed.append(
                    Placed(
                        range: NSRange(location: after, length: 0), start: start, confidence: nil))
                return
            }
            for (offset, run) in replacing.enumerated() {
                let share = Double(offset) / Double(replacing.count)
                placed.append(
                    Placed(range: run.range, start: start + (end - start) * share, confidence: nil))
            }
        }
        for (word, runs) in found {
            fill(before: word, run: runs.lowerBound, until: words[word].start)
            placed.append(
                Placed(
                    range: NSUnionRange(
                        written[runs.lowerBound].range, written[runs.upperBound].range),
                    start: words[word].start, confidence: words[word].confidence))
            nextWord = word + 1
            nextRun = runs.upperBound + 1
        }
        fill(before: words.count, run: written.count, until: words.last?.end ?? 0)
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
        // Words said but removed have no place in the text to be clicked.
        let placed = placed.filter { $0.range.length > 0 }
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

    /// The word being played at `position`: an empty range while words removed
    /// from the text are heard.
    static func playing(_ placed: [Placed], at position: TimeInterval) -> NSRange? {
        placed.last { $0.start <= position }?.range
    }
}
