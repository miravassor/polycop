// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

private func library(holding count: Int) throws -> (URL, [Entry]) {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let entries = try (0..<count).map { index in
        var entry = Entry(
            recording: URL(filePath: "/tmp/Cours \(index).m4a"),
            modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        entry.publish([Segment(start: 0, end: 4, text: "Bonjour à tous.")], partial: false)
        entry.state = .finished
        entry.edit(paragraphAt: 0, text: "Bonjour à toutes et à tous.")
        try HistoryStore.write(entry, in: history)
        return entry
    }
    return (history, entries)
}

/// A removed transcript waits in Recently Deleted, across a relaunch, and
/// comes back with its corrections.
@MainActor
@Test func aRemovedTranscriptCanBeRecovered() throws {
    let (history, entries) = try library(holding: 1)
    defer { try? FileManager.default.removeItem(at: history) }
    let id = entries[0].id

    AppModel(history: history).removeEntry(id)

    let relaunched = AppModel(history: history)
    #expect(relaunched.entry(id) == nil)
    #expect(relaunched.recentlyDeleted.map(\.id) == [id])

    relaunched.recoverEntry(id)
    #expect(relaunched.recentlyDeleted.isEmpty)
    let recovered = try #require(AppModel(history: history).entry(id))
    #expect(recovered.removed == nil)
    #expect(recovered.paragraphs == entries[0].paragraphs && recovered.isEdited)
}

/// Deleting from Recently Deleted, or leaving a transcript there 30 days,
/// deletes its record for good.
@MainActor
@Test func recentlyDeletedEmptiesAfterThirtyDaysOrOnRequest() throws {
    let (history, entries) = try library(holding: 2)
    defer { try? FileManager.default.removeItem(at: history) }
    let model = AppModel(history: history)
    for entry in entries { model.removeEntry(entry.id) }

    model.deleteEntry(entries[0].id)
    model.deleteExpired(now: .now.addingTimeInterval(AppModel.keepsDeleted - 60))
    #expect(model.recentlyDeleted.map(\.id) == [entries[1].id])
    model.deleteExpired(now: .now.addingTimeInterval(AppModel.keepsDeleted + 60))
    #expect(model.recentlyDeleted.isEmpty)

    let relaunched = AppModel(history: history)
    #expect(relaunched.entries.isEmpty && relaunched.recentlyDeleted.isEmpty)
}
