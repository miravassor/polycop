// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Candidate glossary terms found in course material.
///
/// A glossary is a list of written forms, so what is kept are proper names
/// and acronyms, the rare strings the model spells wrong. A word capitalised
/// because it opens a sentence is not one, and a term on half the pages of a
/// document is a header.
nonisolated enum Terms {

    /// Words capitalised because they open a sentence, never because they name.
    private static let banal: Set<String> = [
        "Le", "La", "Les", "Un", "Une", "Des", "Du", "De", "Ce", "Cet", "Cette", "Ces",
        "Il", "Elle", "Ils", "Elles", "On", "Je", "Tu", "Nous", "Vous", "Leur", "Son",
        "Sa", "Ses", "Mon", "Ma", "Mes", "Notre", "Votre", "Donc", "Mais", "Or", "Car",
        "Et", "Ou", "Si", "Quand", "Comme", "Pour", "Par", "Dans", "Sur", "Sous", "Avec",
        "Sans", "Entre", "Chez", "Après", "Avant", "Depuis", "Pendant", "Alors", "Ainsi",
        "Aussi", "Cependant", "Toutefois", "Enfin", "Puis", "Ensuite", "Voilà", "Bien",
        "Tout", "Toute", "Tous", "Toutes", "Autre", "Même", "Plus", "Moins", "Très",
        "Chapitre", "Partie", "Section", "Introduction", "Conclusion", "Bibliographie",
        "Page", "Cours", "Notes", "Exemple", "Question", "Remarque", "Université",
        "Selon", "Certains", "Certaines", "Chaque", "Plusieurs", "Lorsque", "Pourtant",
        "Voici", "Cela", "Celui", "Celle", "Ceux", "Contrairement", "Quelques", "Nombreux",
        "Beaucoup", "Premier", "Première", "Deuxième", "Second", "Seconde", "Nouveau",
        "Nouvelle", "Grand", "Grande", "Petit", "Petite", "Trois", "Deux", "Quatre",
    ]

    /// Capitals that are never a useful term, such as course-structure words,
    /// slide furniture, and common French words shouted in a title.
    private static let banalUppercase: Set<String> = [
        "LE", "LA", "LES", "UN", "UNE", "DES", "DU", "DE", "ET", "OU", "EN", "AU", "AUX",
        "PAR", "POUR", "SUR", "DANS", "AVEC", "SANS", "CE", "CES", "QUI", "QUE", "EST",
        "CM", "TD", "TP", "UE", "EC", "L1", "L2", "L3", "M1", "M2", "S1", "S2", "S3", "S4",
        "PDF", "PPT", "INTRODUCTION", "CONCLUSION", "BIBLIOGRAPHIE", "SOMMAIRE", "PLAN",
        "CHAPITRE", "PARTIE", "EXAMEN", "COURS", "NOTES", "PAGE", "UNIVERSITE",
        "UNIVERSITÉ", "PARIS", "FRANCE", "UFR", "LICENCE", "MASTER",
        "VOTRE", "NOTRE", "LEUR", "LEURS", "SON", "SES", "MON", "MES", "TON", "VOUS",
        "NOUS", "ILS", "ELLE", "ELLES", "COMME", "CARTE", "CADRE", "TOUT", "TOUS",
        "TOUTE", "MEME", "MÊME", "AUSSI", "ENFIN", "ALORS", "ENTRE", "CHEZ", "SOUS",
        "VERS", "DEUX", "TROIS", "PLUS", "MOINS", "BIEN", "FAIT", "ETRE", "ÊTRE",
        "SONT", "ONT", "QUOI", "DONT", "FIN", "DEBUT", "DÉBUT", "SUITE", "POINT",
        "NIVEAU", "TEXTE", "LIVRE", "TITRE", "PLACE", "FORME", "SENS", "TEMPS", "MONDE",
        "ENFANT", "GROUPE", "OBJET", "SUJET",
    ]

    // Computed rather than stored: Regex is not Sendable, so it cannot be a
    // stored constant on a type read from several threads.
    private static var word: Regex<Substring> { /[A-ZÀ-ÖØ-Ýa-zà-öø-ÿ][A-ZÀ-ÖØ-Ýa-zà-öø-ÿ'’-]*/ }
    private static var acronym: Regex<Substring> {
        /\b[A-ZÀ-ÖØ-Ý][A-ZÀ-ÖØ-Ý0-9]+(?:-[A-ZÀ-ÖØ-Ý0-9]+)*\b/
    }

    /// The terms of a document, weakest first, since whisper.cpp keeps the end
    /// of a prompt and the last ones survive a glossary that runs too long.
    /// `attested` holds terms already written by hand, believed even where a
    /// page shouts. The budget stays a little under what the model reads.
    @concurrent
    static func candidates(
        in pages: [String], attested: Set<String> = [], budget: Int = 200
    ) async -> [String] {
        var presence: [String: Int] = [:]
        var sure: Set<String> = []
        for page in pages {
            guard !Task.isCancelled else { return [] }
            let found = terms(on: page, attested: attested)
            for term in found.all { presence[term, default: 0] += 1 }
            sure.formUnion(found.sure)
        }
        // A term on half the pages belongs to the template, not to the lecture.
        // Below a handful of pages there is no template to find, and the rule
        // would throw away the subject itself.
        let furniture = pages.count >= 6 ? max(2, pages.count / 2) : Int.max
        let ranked = presence.keys
            .filter { presence[$0]! < furniture }
            .filter { sure.contains($0) || presence[$0]! >= 2 }
            .sorted { (presence[$0]!, $1) > (presence[$1]!, $0) }
        return fitting(distinct(ranked), within: budget).reversed()
    }

    /// All candidate terms on the page, plus the subset that needs no
    /// corroboration on its own (an acronym, a multi-word name, or a name
    /// found inside a sentence rather than opening one). A name that only
    /// ever opens a sentence is accepted once another page repeats it.
    private static func terms(on page: String, attested: Set<String>) -> (
        all: Set<String>, sure: Set<String>
    ) {
        let acronym = acronym
        let letters = page.filter(\.isLetter)
        // Some teachers write everything in capitals. On such a page a word in
        // capitals is an acronym only if it carries a digit or a hyphen, or if
        // it was written by hand elsewhere.
        let shouts = !letters.isEmpty && letters.filter(\.isUppercase).count * 2 > letters.count
        var found: Set<String> = []
        for match in page.matches(of: acronym) {
            let term = String(match.output)
            let marked = term.contains { $0.isNumber || $0 == "-" }
            if shouts, !marked, !attested.contains(term) { continue }
            found.insert(term)
        }
        var sure = found
        var seen: [String: Int] = [:]
        for name in properNames(in: page) {
            found.insert(name.term)
            seen[name.term, default: 0] += 1
            // Slides are written in bullets, where every line opens a sentence.
            // A name repeated on the page is treated as sure even there.
            if name.sure || seen[name.term]! > 1 { sure.insert(name.term) }
        }
        return (found.filter(acceptable), sure.filter(acceptable))
    }

    /// Runs of capitalised words, read in a single pass rather than with a
    /// regular expression, since a nested quantifier takes minutes on a page
    /// written in capitals.
    ///
    /// A lone name counts only inside a sentence; dropping lone names
    /// entirely would lose exactly the ones a lecture repeats, such as Freud,
    /// Piaget, or Moodle. One that opens a sentence is still refused, since
    /// its capital letter says nothing on its own.
    private static func properNames(in text: String) -> [(term: String, sure: Bool)] {
        var found: [(term: String, sure: Bool)] = []
        var current: [String] = []
        var opensSentence = true
        var previousEnd: String.Index?
        let word = word
        func flush() {
            if current.count >= 2 {
                found.append((current.joined(separator: " "), true))
            } else if current.count == 1 {
                found.append((current[0], !opensSentence))
            }
            current = []
        }
        for match in text.matches(of: word) {
            if let previousEnd,
                text[previousEnd..<match.range.lowerBound].contains(where: {
                    !$0.isWhitespace || $0.isNewline
                })
            {
                flush()
            }
            previousEnd = match.range.upperBound
            let term = String(match.output)
            if capitalised(term), !banal.contains(term), term.count > 2 {
                if current.isEmpty { opensSentence = opens(text, at: match.range.lowerBound) }
                current.append(term)
            } else {
                flush()
            }
        }
        flush()
        return found
    }

    /// Whether nothing but a sentence end stands before this word.
    private static func opens(_ text: String, at index: String.Index) -> Bool {
        guard let previous = text[..<index].reversed().first(where: { !$0.isWhitespace }) else {
            return true
        }
        return ".!?:;•|-–—\u{2022}".contains(previous)
    }

    /// A slide title in capitals is not a name; treating it as one would glue
    /// whole sentences together. Acronyms are handled separately.
    private static func capitalised(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return first.isUppercase && word != word.uppercased()
    }

    private static func acceptable(_ term: String) -> Bool {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard let first = term.first, first.isLetter, term.count >= 2 else { return false }
        if term.count == 2, term != term.uppercased() { return false }
        let marked = term.contains { $0.isNumber || $0 == "-" }
        if term == term.uppercased(), term.count > 6, !marked { return false }
        if term.contains(".") || term.contains("/") || term.contains("\\") { return false }
        let shouted = term.uppercased()
        let numeral = shouted.allSatisfy { "IVXLCDM".contains($0) }
        if banalUppercase.contains(shouted) || numeral { return false }
        return !banal.contains(term)
    }

    /// One form per term. A single word already covered by a higher-ranked,
    /// multi-word expression is dropped, since the model sees that string
    /// either way.
    private static func distinct(_ candidates: [String]) -> [String] {
        var kept: [String] = []
        var seen: Set<String> = []
        for term in candidates {
            let key = term.lowercased()
            if seen.contains(key) { continue }
            let words = Set(key.split(separator: " "))
            if kept.contains(where: {
                words.isSubset(of: Set($0.lowercased().split(separator: " ")))
            }
            ) {
                continue
            }
            seen.insert(key)
            kept.append(term)
        }
        return kept
    }

    /// A prompt wider than the subject pushes the model towards its own words,
    /// so the list stops where the budget does.
    private static func fitting(_ candidates: [String], within budget: Int) -> [String] {
        var kept: [String] = []
        for term in candidates {
            let sentence = Glossary(name: "", text: (kept + [term]).joined(separator: "\n"))
                .prompt()
            guard let sentence, Glossary.estimatedTokens(of: sentence) <= budget else { break }
            kept.append(term)
        }
        return kept
    }
}
