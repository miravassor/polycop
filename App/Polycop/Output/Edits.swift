// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Word-level differences between original and edited paragraphs.
nonisolated enum Edits {
    /// Changed word indices from a longest common subsequence.
    /// Above 250,000 cells, compare only common edges to bound time and memory.
    static func changed(from original: String, to current: String) -> Set<Int> {
        let before = original.split(whereSeparator: \.isWhitespace)
        let after = current.split(whereSeparator: \.isWhitespace)
        guard !after.isEmpty else { return [] }
        guard !before.isEmpty else { return Set(after.indices) }

        guard before.count <= 250_000 / after.count else {
            // Bound work after a large paste; unchanged edges still compare exactly.
            var first = 0
            while first < min(before.count, after.count), before[first] == after[first] {
                first += 1
            }
            var tail = 0
            while tail < min(before.count, after.count) - first,
                before[before.count - tail - 1] == after[after.count - tail - 1]
            { tail += 1 }
            return Set(first..<(after.count - tail))
        }

        // Longest common subsequence, filled from the end so the walk forward
        // keeps the earliest match, which reads better in the text.
        var table = [[Int]](
            repeating: [Int](repeating: 0, count: after.count + 1), count: before.count + 1)
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                table[i][j] =
                    before[i] == after[j]
                    ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var changed: Set<Int> = []
        var i = 0
        var j = 0
        while i < before.count, j < after.count {
            if before[i] == after[j] {
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                changed.insert(j)
                j += 1
            }
        }
        while j < after.count {
            changed.insert(j)
            j += 1
        }
        return changed
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
