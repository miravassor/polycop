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

    /// The pairs of equal words along a longest common subsequence, each
    /// matched as early as it can be, which reads better in the text. Past
    /// 250,000 cells, as after a large paste, only the equal words at both
    /// ends are paired, to bound time and memory.
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

        // An unedited stretch at the start pairs as the walk below would,
        // without a table: most paragraphs are not edited at all.
        var first = 0
        while first < min(old.count, new.count), old[first] == new[first] { first += 1 }
        var pairs = (0..<first).map { ($0, $0) }
        let rows = old.count - first
        let columns = new.count - first + 1
        guard rows > 0, columns > 1 else { return pairs }

        guard rows <= 250_000 / columns else {
            var tail = 0
            while tail < min(rows, columns - 1),
                old[old.count - tail - 1] == new[new.count - tail - 1]
            { tail += 1 }
            return pairs + (0..<tail).reversed().map { (old.count - 1 - $0, new.count - 1 - $0) }
        }

        // Filled from the end, so the walk forward keeps the earliest match.
        var table = [Int](repeating: 0, count: (rows + 1) * columns)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 2, through: 0, by: -1) {
                table[i * columns + j] =
                    old[first + i] == new[first + j]
                    ? table[(i + 1) * columns + j + 1] + 1
                    : max(table[(i + 1) * columns + j], table[i * columns + j + 1])
            }
        }
        var i = 0
        var j = 0
        while i < rows, j < columns - 1 {
            if old[first + i] == new[first + j] {
                pairs.append((first + i, first + j))
                i += 1
                j += 1
            } else if table[(i + 1) * columns + j] >= table[i * columns + j + 1] {
                i += 1
            } else {
                j += 1
            }
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
