// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Subtitle credits Whisper invents over silence, learned from the subtitled
/// video it was trained on.
///
/// A segment matching one of these lines is hidden, not deleted, since the
/// text alone cannot prove it was not said; the window offers to put it back.
/// Matching single words would be worse, since "sous-titres" can be spoken.
nonisolated enum Credits {
    /// Compared without case, outer spaces or punctuation. Drawn from
    /// NVIDIA's Granary list of frequent French hallucinations, whisper.cpp
    /// issue 2660 and a published list of what Whisper writes over noise.
    ///
    /// Phrases a lecturer might plausibly say are deliberately left out.
    /// "Merci", "Merci à tous", "Merci pour votre attention" and "Au revoir"
    /// are on those lists too, but they are also how a lecture ends; only a
    /// sign-off addressed to a video audience belongs here.
    static let lines: Set<String> = [
        "sous-titrage société radio-canada",
        "société radio-canada",
        "radio-canada",
        "sous-titrage fr pays de l'ontario",
        "sous-titres réalisés par la communauté d'amara.org",
        // The same line as whisper.cpp writes it in its other spelling.
        "sous-titres réalisés para la communauté d'amara.org",
        "sous-titrage st' 501",
        "merci d'avoir regardé cette vidéo",
        "merci d'avoir regardé",
        "merci de regarder",
        "abonnez-vous à ma chaîne",
        "abonnez vous à ma chaîne",
        "n'oubliez pas de vous abonner",
        "bonjour à tous et bienvenue sur ma chaîne",
        // The same boilerplate in English, for a lecture transcribed in it.
        "thank you for watching",
        "thanks for watching",
        "thank you for watching this video",
        "subtitles by the amara.org community",
        "please subscribe to my channel",
        "don't forget to subscribe",
    ]

    /// The speech in order, and the credits taken out of it.
    static func separate(_ segments: [Segment]) -> (speech: [Segment], credits: [Segment]) {
        var speech: [Segment] = []
        var credits: [Segment] = []
        for segment in segments {
            if lines.contains(normalized(segment.text)) {
                credits.append(segment)
            } else {
                speech.append(segment)
            }
        }
        return (speech, credits)
    }

    static func notice(_ credits: [Segment]) -> String? {
        guard let first = credits.first else { return nil }
        let line = first.text.trimmingCharacters(in: .whitespaces)
        if credits.count == 1 {
            return String(
                localized:
                    "Hid “\(line)”, which matches a subtitle credit Whisper invents over silence.")
        }
        return String(
            localized:
                "Hid \(credits.count) lines that match subtitle credits Whisper invents over silence, such as “\(line)”."
        )
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
    }
}
