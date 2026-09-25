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

    @Test func reviewFlagsPersistWithoutChangingTextOrExports() throws {
        let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: history) }
        var entry = sample()
        entry.isSaved = true
        try HistoryStore.write(entry, in: history)
        let model = AppModel(history: history)
        model.toggleReview(entry.id, paragraphAt: 1)
        let restored = try #require(HistoryStore.all(in: history).entries.first)
        #expect(restored.reviewParagraphs == [1])
        #expect(restored.paragraphs == entry.paragraphs)
        #expect(restored.isSaved)
        #expect(!restored.isEdited)
        model.edit(entry.id, paragraphAt: 1, text: "Correction.")
        model.undo(entry.id)
        #expect(model.entry(entry.id)?.reviewParagraphs == [1])
        model.toggleReview(entry.id, paragraphAt: 1)
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
