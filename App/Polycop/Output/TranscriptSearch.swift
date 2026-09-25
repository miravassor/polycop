// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated enum TranscriptSearch {
    struct Match: Equatable {
        let paragraph: Int
        let range: NSRange
    }

    static func matches(in paragraphs: [Transcript.Paragraph], query: String) -> [Match] {
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
                result.append(Match(paragraph: index, range: range))
                offset = NSMaxRange(range)
            }
        }
        return result
    }
}
