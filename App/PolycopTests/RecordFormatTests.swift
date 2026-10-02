// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

// Records as each release wrote them, with made up text, decoded by this one.
// A release that changes what is stored adds its own. A stored property added
// since a release must be optional: synthesized decoding ignores default
// values, so a record written before the property existed would no longer
// load, and the library would report it as damaged.

private let records = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/records")

/// A folder of its own holding one file, named as the app names it.
private func folder(holding name: String, as stored: String) throws -> URL {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: records.appending(path: name), to: folder.appending(path: stored))
    return folder
}

@Test(arguments: ["0.2.0", "0.3.0", "0.3.2"])
func aTranscriptWrittenByAnEarlierReleaseStillLoads(release: String) throws {
    let name = "entry-\(release).json"
    let written = try JSONSerialization.jsonObject(
        with: Data(contentsOf: records.appending(path: name)))
    let id = try #require((written as? [String: Any])?["id"] as? String)
    let history = try folder(holding: name, as: id + ".json")
    defer { try? FileManager.default.removeItem(at: history) }

    let library = HistoryStore.all(in: history)

    #expect(library.damaged.isEmpty)
    let entry = try #require(library.entries.first)
    #expect(entry.name == "Cours 12 (2).m4a")
    #expect(entry.paragraphs.first?.text == "Bonjour à toutes et à tous.")
    #expect(entry.isEdited && entry.original.first?.text != entry.paragraphs.first?.text)
    #expect(entry.decoded.count == 2)
    // What each release added is there from that release on, and absent before.
    #expect((entry.decoded.first?.words != nil) == (release != "0.2.0"))
    #expect((entry.courseCorrections != nil) == (release != "0.2.0"))
    #expect((entry.readingParagraph != nil) == (release == "0.3.2"))
    switch release {
    case "0.2.0": #expect(entry.state == .stopped)
    case "0.3.0": #expect(entry.state == .failed("The model could not be read."))
    default: #expect(entry.state == .finished)
    }
}

@Test func aFolderListWrittenByAnEarlierReleaseStillLoads() throws {
    let history = try folder(holding: "folders-0.2.0.json", as: "folders.json")
    defer { try? FileManager.default.removeItem(at: history) }

    #expect(try HistoryStore.folders(in: history).map(\.name) == ["Philosophie"])
}

@Test func courseCorrectionsWrittenByAnEarlierReleaseStillLoad() throws {
    let glossaries = try folder(
        holding: "corrections-0.3.0.json", as: "Philosophie.corrections.json")
    defer { try? FileManager.default.removeItem(at: glossaries) }

    #expect(
        try CourseCorrections.all(for: "Philosophie", in: glossaries)
            == [CourseCorrection(text: "des cartes", replacement: "Descartes")])
}

/// A copy of the 0.3.2 record, changed as `change` says, in a folder of its own.
private func changed(_ change: (inout [String: Any]) -> Void) throws -> URL {
    var record = try #require(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: records.appending(path: "entry-0.3.2.json")))
            as? [String: Any])
    change(&record)
    let id = try #require(record["id"] as? String)
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: record).write(
        to: folder.appending(path: id + ".json"))
    return folder
}

/// Before 0.4, MOSS could save a turn before the one it follows, and the
/// record was refused at the next launch. It opens, each text with its time,
/// and the reading place follows its paragraph.
@Test func aRecordWithParagraphsOutOfOrderOpensSorted() throws {
    let history = try changed { record in
        for key in ["paragraphs", "originalParagraphs", "decoded"] {
            record[key] = (record[key] as? [Any]).map { Array($0.reversed()) }
        }
        record["readingParagraph"] = 0
    }
    defer { try? FileManager.default.removeItem(at: history) }

    let library = HistoryStore.all(in: history)

    #expect(library.damaged.isEmpty)
    let entry = try #require(library.entries.first)
    #expect(entry.paragraphs.map(\.start) == [0, 4000])
    #expect(entry.paragraphs.first?.text == "Bonjour à toutes et à tous.")
    #expect(entry.original.map(\.start) == [0, 4000])
    #expect(entry.decoded.map(\.start) == [0, 4])
    #expect(entry.readingParagraph == 1)
    #expect(entry.isEdited)
}

/// A playback position out of bounds is forgotten rather than refusing the
/// transcript, or trapping when the player shows it.
@Test func aPlaybackPositionOutOfBoundsIsForgotten() throws {
    let history = try changed { record in
        record["playbackPosition"] = 1e100
    }
    defer { try? FileManager.default.removeItem(at: history) }

    let library = HistoryStore.all(in: history)

    #expect(library.damaged.isEmpty)
    let entry = try #require(library.entries.first)
    #expect(entry.playbackPosition == nil)
    #expect(PlayerBar.clock(1e100) == PlayerBar.clock(AudioDecoder.longestRecording + 60))
}
