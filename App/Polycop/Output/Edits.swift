// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Word-level differences between original and edited paragraphs.
nonisolated enum Edits {
    /// Largest combined middle slice handed to `difference(from:)`. The
    /// standard library's diff grows with the square of the edit distance, so
    /// bounding the sum keeps time and memory bounded even when one side is
    /// much longer than the other, as after a large paste.
    static let diffLimit = 1_000

    /// Changed word indices: the words of `current` left out of the pairs.
    static func changed(from original: String, to current: String) -> Set<Int> {
        let after = current.split(whereSeparator: \.isWhitespace)
        let paired = pairs(original.split(whereSeparator: \.isWhitespace), after).map(\.1)
        return Set(after.indices).subtracting(paired)
    }

    /// The pairs of equal words a shortest edit from `before` to `after` keeps,
    /// in order. Shared ends are paired first; when the remaining middle passes
    /// `diffLimit` words combined, only those ends are paired.
    static func pairs<Word: Hashable>(_ before: [Word], _ after: [Word]) -> [(Int, Int)] {
        let shorter = min(before.count, after.count)
        var prefix = 0
        while prefix < shorter, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix,
            before[before.count - 1 - suffix] == after[after.count - 1 - suffix]
        {
            suffix += 1
        }

        let beforeTail = before.count - suffix
        let afterTail = after.count - suffix
        let oldMiddle = before[prefix..<beforeTail]
        let newMiddle = after[prefix..<afterTail]
        let canDiff =
            !oldMiddle.isEmpty && !newMiddle.isEmpty
            && oldMiddle.count + newMiddle.count <= diffLimit

        var pairs: [(Int, Int)] = []
        pairs.reserveCapacity(
            prefix + suffix + (canDiff ? min(oldMiddle.count, newMiddle.count) : 0))
        for index in 0..<prefix { pairs.append((index, index)) }
        if canDiff {
            appendMiddlePairs(from: oldMiddle, to: newMiddle, offset: prefix, into: &pairs)
        }
        for offset in 0..<suffix { pairs.append((beforeTail + offset, afterTail + offset)) }
        return pairs
    }

    private static func appendMiddlePairs<Word: Hashable>(
        from before: ArraySlice<Word>, to after: ArraySlice<Word>, offset: Int,
        into pairs: inout [(Int, Int)]
    ) {
        // Numbered, words compare in one step rather than character by character.
        var numbers: [Word: Int] = [:]
        func number(_ word: Word) -> Int {
            if let number = numbers[word] { return number }
            numbers[word] = numbers.count
            return numbers.count - 1
        }
        let old = before.map(number)
        let new = after.map(number)

        var removed = [Bool](repeating: false, count: old.count)
        var inserted = [Bool](repeating: false, count: new.count)
        for change in new.difference(from: old) {
            switch change {
            case .remove(let index, _, _): removed[index] = true
            case .insert(let index, _, _): inserted[index] = true
            }
        }
        var next = 0
        for index in old.indices where !removed[index] {
            while inserted[next] { next += 1 }
            pairs.append((offset + index, offset + next))
            next += 1
        }
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
