// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

@Suite @MainActor
struct ReviewFeaturesTests {
    @Test func searchHandlesAccentsUnicodeAndLiteralPunctuation() {
        let paragraphs = [
            Transcript.Paragraph(start: 0, text: "🧪 École, e\u{301}cole et ECOLE."),
            Transcript.Paragraph(start: 30_000, text: "Un [mot], puis [mot]."),
        ]
        let matches = TranscriptSearch.matches(in: paragraphs, query: "ecole")
        #expect(matches.count == 3)
        #expect(matches.allSatisfy { $0.paragraph == 0 })
        #expect(
            matches.map { (paragraphs[0].text as NSString).substring(with: $0.range) }
                == ["École", "e\u{301}cole", "ECOLE"])
        #expect(TranscriptSearch.matches(in: paragraphs, query: "[mot]").count == 2)
        #expect(TranscriptSearch.matches(in: paragraphs, query: " \n ").isEmpty)
        #expect(TranscriptSearch.matches(in: paragraphs, query: "absent").isEmpty)
    }

    @Test func findStepsRoundTheResultsAndKeepsItsPlaceAfterAnEdit() {
        var paragraphs = [
            Transcript.Paragraph(start: 0, text: "mot un, mot deux"),
            Transcript.Paragraph(start: 30_000, text: "mot trois"),
        ]
        var find = TranscriptFind()
        find.query = "mot"
        find.refresh(in: paragraphs, startingOver: true)
        #expect(find.matches.count == 3)
        #expect(find.current?.paragraph == 0)

        find.step(forward: false)
        #expect(find.index == 2)
        find.step(forward: true)
        #expect(find.index == 0)
        find.step(forward: true)
        find.step(forward: true)

        // An edit that removes the result shown shows none, so the page stays
        // where the reader types; the next step goes round to the first.
        paragraphs[1].text = "trois"
        find.refresh(in: paragraphs, startingOver: false)
        #expect(find.current == nil)
        find.step(forward: true)
        #expect(find.current == find.matches.first)

        find.close()
        #expect(!find.isShown && find.query.isEmpty)
        find.refresh(in: paragraphs, startingOver: true)
        #expect(find.current == nil)
        find.step(forward: true)
        #expect(find.index == 0)
    }

    /// A result of five letters, the length of the queries below.
    private func match(_ paragraph: Int, at location: Int) -> TranscriptSearch.Match {
        TranscriptSearch.Match(paragraph: paragraph, range: NSRange(location: location, length: 5))
    }

    /// Correcting the result shown, or text before it, never shows another
    /// one in its place: the reader steps to the result that waits there.
    @Test func findKeepsItsPlaceWhenAnEditMovesTheResults() {
        var paragraphs = [
            Transcript.Paragraph(start: 0, text: "froid un, froid deux, froid trois"),
            Transcript.Paragraph(start: 30_000, text: "froid quatre"),
        ]
        var find = TranscriptFind()
        find.query = "froid"
        find.refresh(in: paragraphs, startingOver: true)
        find.step(forward: true)
        #expect(find.current == match(0, at: 10))

        // Typed over: the result after it waits, unshown.
        paragraphs[0].text = "froid un, Freud deux, froid trois"
        find.refresh(in: paragraphs, startingOver: false)
        #expect(find.current == nil)
        find.step(forward: true)
        #expect(find.current == match(0, at: 22))

        // Text taken out before it, a result with it: the same result waits.
        paragraphs[0].text = "un, Freud deux, froid trois"
        find.refresh(in: paragraphs, startingOver: false)
        #expect(find.current == nil)
        find.step(forward: true)
        #expect(find.current == match(0, at: 16))

        // An edit elsewhere that changes no result keeps the one shown.
        paragraphs[1].text = "froid cinq"
        find.refresh(in: paragraphs, startingOver: false)
        #expect(find.current?.range.location == 16)
    }

    /// A replacement that still matches, as "Freud" does "freud", is passed
    /// over, so pressing Replace again corrects the next one.
    @Test func replaceMovesPastAReplacementThatStillMatches() throws {
        var paragraphs = [
            Transcript.Paragraph(start: 0, text: "freud et freud"),
            Transcript.Paragraph(start: 30_000, text: "encore freud"),
        ]
        var find = TranscriptFind()
        find.query = "freud"
        find.refresh(in: paragraphs, startingOver: true)
        let first = try #require(find.current)
        #expect(first.range.location == 0)

        paragraphs[0].text = "Freud et freud"
        find.showFirst(after: first, replacedBy: "Freud", in: paragraphs)
        #expect(find.current == match(0, at: 9))

        paragraphs[0].text = "Freud et Freud"
        find.showFirst(after: try #require(find.current), replacedBy: "Freud", in: paragraphs)
        #expect(find.current?.paragraph == 1)
        // The refresh that follows the edit changes nothing.
        find.refresh(in: paragraphs, startingOver: false)
        #expect(find.current?.paragraph == 1)
    }

    @Test func reviewFlagsPersistWithoutChangingTextOrExports() async throws {
        let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: history) }
        var entry = sample()
        entry.isSaved = true
        try HistoryStore.write(entry, in: history)
        let model = AppModel(history: history)
        model.toggleReview(entry.id, paragraphAt: 1)
        await model.finishWrites()
        let restored = try #require(HistoryStore.all(in: history).entries.first)
        #expect(restored.reviewParagraphs == [1])
        #expect(restored.paragraphs == entry.paragraphs)
        #expect(restored.isSaved)
        #expect(!restored.isEdited)
        model.edit(entry.id, paragraphAt: 1, text: "Correction.")
        model.undo(entry.id)
        #expect(model.entry(entry.id)?.reviewParagraphs == [1])
        model.toggleReview(entry.id, paragraphAt: 1)
        await model.finishWrites()
        #expect(HistoryStore.all(in: history).entries.first?.reviewParagraphs.isEmpty == true)
    }

    @Test func oldHistoryAndCopiesKeepTheExpectedReviewState() throws {
        var entry = sample()
        let old = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(Entry.self, from: old).reviewParagraphs.isEmpty)
        entry.toggleReview(paragraphAt: 1)
        #expect(entry.duplicated(among: []).reviewParagraphs == [1])
        #expect(entry.retrying().reviewMarks == nil)
        entry.toggleReview(paragraphAt: -1)
        entry.toggleReview(paragraphAt: 99)
        #expect(entry.reviewParagraphs == [1])
    }

    @Test func flagsFollowAudioWhenParagraphsAreRegrouped() {
        var entry = sample()
        entry.toggleReview(paragraphAt: 1)
        entry.paragraphs = [
            .init(start: 0, text: "First."),
            .init(start: 15_000, text: "Regrouped passage."),
            .init(start: 45_000, text: "Last."),
        ]
        #expect(entry.reviewMarks == [30_000])
        #expect(entry.reviewParagraphs == [1])
        entry.toggleReview(paragraphAt: 1)
        #expect(entry.reviewMarks?.isEmpty == true)
    }

    private func sample() -> Entry {
        var entry = Entry(
            recording: URL(filePath: "/tmp/synthetic-review.wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil,
            skipsSilence: false, subtitles: false)
        entry.state = .finished
        entry.paragraphs = [.init(start: 0, text: "First."), .init(start: 30_000, text: "Second.")]
        entry.originalParagraphs = entry.paragraphs
        return entry
    }
}
