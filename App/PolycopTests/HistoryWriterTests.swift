// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

private func entry(saying text: String, id: UUID = UUID()) -> Entry {
    var entry = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.id = id
    entry.publish([Segment(start: 0, end: 2, text: text)], partial: false)
    entry.state = .finished
    return entry
}

/// Corrections follow one another faster than a long lecture is encoded.
/// Whatever the timing, the last one asked is the one on disk.
@MainActor
@Test func theLastWriteOfAnEntryIsTheOneLeftOnDisk() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = HistoryWriter(folder: folder)
    let id = UUID()
    var outcomes = 0

    for number in 1...20 {
        writer.write(entry(saying: "Version \(number).", id: id)) { _ in outcomes += 1 }
    }
    await writer.finish()

    #expect(outcomes == 20)
    let stored = try #require(HistoryStore.all(in: folder).entries.first)
    #expect(stored.paragraphs.first?.text == "Version 20.")
}

/// Removing a transcript while its writes are still queued must not let one
/// of them put the file back.
@MainActor
@Test func aDeleteComesAfterTheWritesAskedBeforeIt() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = HistoryWriter(folder: folder)
    let removed = entry(saying: "Removed.")

    writer.write(removed) { _ in }
    try writer.delete(removed.id)
    await writer.finish()

    #expect(HistoryStore.all(in: folder).entries.isEmpty)
}
