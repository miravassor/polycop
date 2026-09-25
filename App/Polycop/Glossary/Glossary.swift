// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The vocabulary of one course, sent to the model as a prompt so that rare
/// words, authors and concepts come out spelled as they are taught.
///
/// Stored as the text the user typed, one term per line or comma separated.
/// Terms and the prompt are derived from it on demand, so the editor never
/// rewrites text the user is still typing.
nonisolated struct Glossary: Identifiable, Equatable, Sendable {
    let name: String
    var text: String

    var id: String { name }

    /// Whisper reads at most this many prompt tokens when the prompt is
    /// carried into every window, keeping the last ones. Past this, the first
    /// terms are dropped with nothing but a log line (`whisper_full_with_state`,
    /// v1.9.4).
    static let tokenBudget = 223

    /// Characters per token, for an estimate when no model is open to count.
    /// Not a hard bound, since the ratio varies with the vocabulary; the exact
    /// count taken when a job starts decides whether a glossary fits.
    static let charactersPerToken = 2.8

    static func estimatedTokens(of prompt: String) -> Int {
        Int((Double(prompt.count) / charactersPerToken).rounded(.up))
    }

    var terms: [String] { Glossary.terms(in: text) }

    /// The sentence sent to the model, "Ce cours porte sur a, b.". This form
    /// recalls more of the glossary than a bare list; English follows it word
    /// for word. The course name is left out, since a free-form name can
    /// break the French sentence.
    func prompt(in language: String = "fr") -> String? {
        let terms = terms
        guard !terms.isEmpty else { return nil }
        let list = terms.joined(separator: ", ")
        return language == "en" ? "This lecture is about \(list)." : "Ce cours porte sur \(list)."
    }

    /// Terms from free text, one per line or comma separated. A single-line
    /// prompt sentence such as "Ce cours porte sur ..." imports as well,
    /// keeping only its terms. Apostrophes are straightened, since the Mac
    /// editor types curly ones and the model writes straight ones.
    static func terms(in text: String) -> [String] {
        let text = text.replacingOccurrences(of: "\u{2019}", with: "'")
        var body = Substring(text)
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let english = line.hasPrefix("This lecture is about ")
        if english || line.hasPrefix("Ce cours"), !line.contains(where: \.isNewline),
            let range = line.range(of: english ? "This lecture is about " : " porte sur ")
        {
            body = line[range.upperBound...]
            while body.last == "." || body.last?.isWhitespace == true { body = body.dropLast() }
        }
        var seen = Set<String>()
        return
            body
            // `isNewline`, not "\n", since a Windows line ending is one
            // Character. A null character separates too, since passed to C it
            // would end the prompt.
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "\u{0}" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
