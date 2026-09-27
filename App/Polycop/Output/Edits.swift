// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Word-level differences between original and edited paragraphs.
nonisolated enum Edits {
    /// Changed word indices: the words of `current` left out of the pairs.
    static func changed(from original: String, to current: String) -> Set<Int> {
        let after = current.split(whereSeparator: \.isWhitespace)
        let paired = pairs(original.split(whereSeparator: \.isWhitespace), after).map(\.1)
        return Set(after.indices).subtracting(paired)
    }

    /// The pairs of equal words a shortest edit from `before` to `after` keeps,
    /// in order. Past 250,000 cells, as after a large paste, only the equal
    /// words at both ends are paired, to bound time and memory.
    static func pairs<Word: Hashable>(_ before: [Word], _ after: [Word]) -> [(Int, Int)] {
        // Numbered, words compare in one step rather than character by character.
        var numbers: [Word: Int] = [:]
        func number(_ word: Word) -> Int {
            if let number = numbers[word] { return number }
            numbers[word] = numbers.count
            return numbers.count - 1
        }
        let old = before.map(number)
        let new = after.map(number)
        guard !old.isEmpty, !new.isEmpty else { return [] }

        guard old.count <= 250_000 / new.count else {
            var first = 0
            while first < min(old.count, new.count), old[first] == new[first] { first += 1 }
            var tail = 0
            while tail < min(old.count, new.count) - first,
                old[old.count - tail - 1] == new[new.count - tail - 1]
            { tail += 1 }
            return (0..<first).map { ($0, $0) }
                + (0..<tail).reversed().map { (old.count - 1 - $0, new.count - 1 - $0) }
        }

        // The standard library's diff takes time in proportion to the edits,
        // which are few, rather than to the square of the length.
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var pairs: [(Int, Int)] = []
        var next = 0
        for index in old.indices where !removed.contains(index) {
            while inserted.contains(next) { next += 1 }
            pairs.append((index, next))
            next += 1
        }
        return pairs
    }

    /// The same positions as ranges of the text, for colouring it.
    static func ranges(of words: Set<Int>, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = 0
        var start: String.Index?
        for position in text.indices {
            let space = text[position].isWhitespace
            if !space, start == nil { start = position }
            if space, let from = start {
                if words.contains(index) { ranges.append(from..<position) }
                index += 1
                start = nil
            }
        }
        if let from = start, words.contains(index) { ranges.append(from..<text.endIndex) }
        return ranges
    }
}
