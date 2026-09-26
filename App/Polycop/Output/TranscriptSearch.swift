// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated enum TranscriptSearch {
    struct Match: Equatable {
        let paragraph: Int
        let range: NSRange
    }

    /// With `wholeWords`, a match must not continue a word on either side, so
    /// a correction remembered for "Ca" leaves "Carl" alone.
    static func matches(
        in paragraphs: [Transcript.Paragraph], query: String, wholeWords: Bool = false
    ) -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var result: [Match] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let text = paragraph.text as NSString
            var offset = 0
            while offset < text.length {
                let range = text.range(
                    of: query, options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: offset, length: text.length - offset))
                guard range.location != NSNotFound, range.length > 0 else { break }
                if !wholeWords || isWholeWord(range, in: text) {
                    result.append(Match(paragraph: index, range: range))
                }
                offset = NSMaxRange(range)
            }
        }
        return result
    }

    /// Whether `range` neither starts nor ends in the middle of a word.
    static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        func isLetter(at index: Int) -> Bool {
            guard index >= 0, index < text.length,
                let scalar = UnicodeScalar(text.character(at: index))
            else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        let end = NSMaxRange(range)
        return !(isLetter(at: range.location - 1) && isLetter(at: range.location))
            && !(isLetter(at: end - 1) && isLetter(at: end))
    }
}
