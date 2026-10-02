// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension Entry {
    /// Applies each course correction as the user's own, so it can be compared
    /// with what the engine wrote. Only whole words are replaced, since no one
    /// reviews these matches, and a place that already reads as the
    /// replacement, such as "Sigmund Freud" for "Freud", is left alone.
    mutating func apply(_ corrections: [CourseCorrection]) {
        for correction in corrections {
            let matches = TranscriptSearch.matches(
                in: paragraphs, query: correction.text, wholeWords: true
            ).filter { !reads(correction.replacement, around: $0) }
            replace(matches, with: correction.replacement)
        }
    }

    /// Whether the text around a match already reads as `replacement`. A
    /// replacement that only respells the match must be there exactly: "ca"
    /// does not yet read "ça". One that adds words around it, as "Sigmund
    /// Freud" does to "Freud", needs those words exactly, while the matched
    /// words count as search counts them, so "L’homme social" already reads
    /// "l'homme social".
    private func reads(_ replacement: String, around match: TranscriptSearch.Match) -> Bool {
        let text = Apostrophes.straightened(paragraphs[match.paragraph].text) as NSString
        let replacement = Apostrophes.straightened(replacement) as NSString
        let matched = text.substring(with: match.range)
        let inside = replacement.range(
            of: matched, options: [.caseInsensitive, .diacriticInsensitive])
        guard inside.location != NSNotFound else { return false }
        if inside.length == replacement.length { return matched == replacement as String }
        let before = NSRange(
            location: match.range.location - inside.location, length: inside.location)
        let after = NSRange(
            location: NSMaxRange(match.range), length: replacement.length - NSMaxRange(inside))
        guard before.location >= 0, NSMaxRange(after) <= text.length else { return false }
        return text.substring(with: before) == replacement.substring(to: inside.location)
            && text.substring(with: after) == replacement.substring(from: NSMaxRange(inside))
    }

    /// Whether the only changes are the course corrections. Those are applied
    /// again after the paragraphs are rebuilt, so they do not stand in the way
    /// of repairing repeats or putting credits back.
    var hasOnlyCourseCorrections: Bool {
        guard isEdited else { return true }
        guard let courseCorrections, !courseCorrections.isEmpty else { return false }
        var uncorrected = self
        uncorrected.paragraphs = original
        uncorrected.isEdited = false
        uncorrected.apply(courseCorrections)
        return uncorrected.paragraphs == paragraphs
    }
}
