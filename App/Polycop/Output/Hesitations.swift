// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Hesitation sounds, removed from a text export on request.
///
/// Only sounds without meaning are listed. Words such as "ben", "du coup" or
/// "voilà" can carry sense, so they stay and the text keeps its meaning.
nonisolated enum Hesitations {
    /// Built where it is used, since a Regex is not Sendable.
    private static var sound: Regex<Substring> {
        /\b(?:e+u+h+|h+e+u+|h+u+m+|h+m+|m+h+|bah|u+m+|u+h+|e+r+m+)\b(?:,|…|\.\.\.)*\s*/
            .ignoresCase()
    }

    /// The text without its hesitations. A sentence that opened on one opens
    /// on the next word, capitalized. A text that was nothing else is empty.
    static func removed(from text: String) -> String {
        var result = ""
        var capitalizesNext = false
        var rest = text[...]
        for match in text.matches(of: sound) {
            append(
                text[rest.startIndex..<match.range.lowerBound], to: &result,
                capitalizing: capitalizesNext)
            let before = result.trimmingCharacters(in: .whitespaces)
            capitalizesNext = before.isEmpty || before.last.map { ".!?…".contains($0) } == true
            rest = text[match.range.upperBound...]
            // A hesitation said as a sentence of its own takes its full stop
            // or question mark with it.
            if capitalizesNext, let end = rest.prefixMatch(of: /[.!?]+\s*/) {
                rest = rest[end.range.upperBound...]
            }
        }
        append(rest, to: &result, capitalizing: capitalizesNext)
        let cleaned =
            result
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            // A comma left before the end of the sentence goes with the hesitation.
            .replacingOccurrences(of: ",.", with: ".")
            .replacingOccurrences(of: ", ?", with: " ?")
            .replacingOccurrences(of: ", !", with: " !")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.contains { $0.isLetter || $0.isNumber } ? cleaned : ""
    }

    private static func append(_ piece: Substring, to result: inout String, capitalizing: Bool) {
        guard capitalizing, let first = piece.first else {
            result += piece
            return
        }
        result += first.uppercased() + piece.dropFirst()
    }
}
