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

@Test(arguments: ["0.2.0", "0.3.0", "0.3.2", "0.4.0"])
func aTranscriptWrittenByAnEarlierReleaseStillLoads(release: String) throws {
    let name = "entry-\(release).json"
    let written = try JSONSerialization.jsonObject(
        with: Data(contentsOf: records.appending(path: name)))
    let id = try #require((written as? [String: Any])?["id"] as? String)
    let history = try folder(holding: name, as: id + ".json")
    defer { try? FileManager.default.removeItem(at: history) }

    let library = HistoryStore.all(in: history)

    #expect(library.unavailable.isEmpty)
    let entry = try #require(library.entries.first)
    #expect(entry.name == "Cours 12 (2).m4a")
    #expect(entry.paragraphs.first?.text == "Bonjour à toutes et à tous.")
    #expect(entry.isEdited && entry.original.first?.text != entry.paragraphs.first?.text)
    #expect(entry.decoded.count == 2)
    // What each release added is there from that release on, and absent before.
    #expect((entry.decoded.first?.words != nil) == (release != "0.2.0"))
    #expect((entry.courseCorrections != nil) == (release != "0.2.0"))
    #expect((entry.readingParagraph != nil) == ["0.3.2", "0.4.0"].contains(release))
    #expect((entry.exportsWord == true) == (release == "0.4.0"))
    #expect((entry.keepsSettings == true) == (release == "0.4.0"))
    #expect((entry.removed != nil) == (release == "0.4.0"))
    #expect(entry.dismissedWarnings == nil)
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

    #expect(library.unavailable.isEmpty)
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

    #expect(library.unavailable.isEmpty)
    let entry = try #require(library.entries.first)
    #expect(entry.playbackPosition == nil)
    #expect(PlayerBar.clock(1e100) == PlayerBar.clock(AudioDecoder.longestRecording + 60))
}

/// A format this version does not know, whether or not it still decodes, is left
/// out of the library with its file as it was, so that nothing is lost by opening
/// the library with an earlier version. This one went to Recently Deleted long
/// ago, so a version that read it would delete it for good at launch.
@MainActor
@Test(arguments: [false, true])
func aRecordInANewerFormatIsLeftOutUntouched(stillDecodes: Bool) async throws {
    let history = try changed { record in
        record["requires"] = HistoryStore.knownFormat + 1
        record["removed"] = 0
        if !stillDecodes { record["paragraphs"] = ["in": "a shape not known yet"] }
    }
    defer { try? FileManager.default.removeItem(at: history) }
    let name = try #require(FileManager.default.contentsOfDirectory(atPath: history.path()).first)
    let file = history.appending(path: name)
    let written = try Data(contentsOf: file)
    let other = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    try HistoryStore.write(other, in: history)

    let library = HistoryStore.all(in: history)
    let record = try #require(library.unavailable.first)
    #expect(record.needsNewerVersion)
    #expect(record.file.lastPathComponent == name)
    #expect(record.name == "Cours 12 (2).m4a")
    #expect(library.entries.map(\.id) == [other.id])

    let model = AppModel(history: history)
    #expect(model.unavailable.map(\.file.lastPathComponent) == [name])
    #expect(model.libraryWarning == nil)
    #expect(model.entries.map(\.id) == [other.id])
    await model.finishWrites()
    #expect(try Data(contentsOf: file) == written)
}

/// A number that says nothing about the format does not hide that a record is
/// damaged.
@Test(arguments: [HistoryStore.knownFormat, 0])
func aDamagedRecordIsNotTakenForANewerOne(format: Int) throws {
    let history = try changed { record in
        record["requires"] = format
        record["paragraphs"] = ["in": "a shape not known yet"]
    }
    defer { try? FileManager.default.removeItem(at: history) }

    let library = HistoryStore.all(in: history)

    #expect(library.unavailable.map(\.needsNewerVersion) == [false])
}

/// A record in the format this version knows opens, and keeps saying so.
@Test func aRecordInTheKnownFormatOpensAndStaysInIt() throws {
    let history = try changed { $0["requires"] = HistoryStore.knownFormat }
    defer { try? FileManager.default.removeItem(at: history) }

    let entry = try #require(HistoryStore.all(in: history).entries.first)
    try HistoryStore.write(entry, in: history)

    #expect(HistoryStore.all(in: history).entries == [entry])
    #expect(entry.requires == HistoryStore.knownFormat)
}

/// What this version writes keeps every key a release wrote, which the releases
/// before it read, and says which version wrote it.
@Test(arguments: ["0.2.0", "0.3.0", "0.3.2", "0.4.0"])
func rewritingARecordLosesNoKey(release: String) throws {
    let name = "entry-\(release).json"
    let read = {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])
    }
    let stored = try read(records.appending(path: name))
    let id = try #require(stored["id"] as? String)
    let history = try folder(holding: name, as: id + ".json")
    defer { try? FileManager.default.removeItem(at: history) }

    try HistoryStore.write(
        #require(HistoryStore.all(in: history).entries.first), in: history)

    let rewritten = try read(history.appending(path: id + ".json"))
    #expect(Set(stored.keys).subtracting(rewritten.keys).isEmpty)
    #expect(rewritten["writtenBy"] as? String == Bundle.main.shortVersion)
    #expect(Bundle.main.shortVersion != nil)
    #expect(rewritten["requires"] == nil)
}

/// A damaged record keeps what still reads of it, so that it is listed under its
/// name in its folder. Unknown folders count as none, as for a transcript, and a
/// folder that holds one is not empty.
@MainActor
@Test func aDamagedRecordIsListedWhereItBelongs() throws {
    let folder = UUID()
    let history = try changed { record in
        record["paragraphs"] = ["in": "a shape not known"]
        record["title"] = "Made up title"
        record["folderID"] = folder.uuidString
    }
    defer { try? FileManager.default.removeItem(at: history) }
    try HistoryStore.writeFolders([TranscriptFolder(id: folder, name: "Made up")], in: history)

    let model = AppModel(history: history)

    #expect(model.unavailable(in: folder).map(\.name) == ["Made up title"])
    #expect(model.unavailable(in: nil).isEmpty)
    #expect(model.holdsTranscripts(folder))
    try model.removeFolder(folder)
    #expect(model.folders.map(\.id) == [folder])

    try HistoryStore.writeFolders([], in: history)
    #expect(AppModel(history: history).unavailable(in: nil).map(\.name) == ["Made up title"])
}

/// Files nothing identifies are listed together. One that still says it was
/// removed stays with Recently Deleted, and is listed once.
@MainActor
@Test func whatNothingIdentifiesIsListedApart() throws {
    let history = try changed { record in
        record["paragraphs"] = ["in": "a shape not known"]
        record["recording"] = nil
        record["title"] = nil
        record["removed"] = 0
    }
    defer { try? FileManager.default.removeItem(at: history) }
    let unreadable = history.appending(path: UUID().uuidString + ".json")
    try Data("{ not a record".utf8).write(to: unreadable)

    let model = AppModel(history: history)

    #expect(model.unavailable.count == 2)
    #expect(model.unidentifiedFiles.map(\.lastPathComponent) == [unreadable.lastPathComponent])
    #expect(model.unavailable.filter { $0.removed != nil }.map(\.name) == [nil])
    #expect(model.unavailable(in: nil).isEmpty)
}

/// A newer format can change any stored property. Whichever it changes, the
/// record is still known as newer, and keeps what still reads.
@Test(arguments: ["recording", "folderID", "removed", "title"])
func aNewerRecordIsNotTakenForADamagedOneWhenAPropertyChangedShape(key: String) throws {
    let history = try changed { record in
        record["requires"] = HistoryStore.knownFormat + 1
        record["title"] = "Made up title"
        record[key] = ["in": "a shape not known"]
    }
    defer { try? FileManager.default.removeItem(at: history) }

    let record = try #require(HistoryStore.all(in: history).unavailable.first)

    #expect(record.needsNewerVersion)
    #expect(record.name == (key == "title" ? "Cours 12.m4a" : "Made up title"))
}

/// A folder that lists nothing can be deleted, as with a removed transcript,
/// even when a record it no longer lists still names it.
@MainActor
@Test func aFolderHoldsOnlyWhatItLists() throws {
    let folder = UUID()
    let history = try changed { record in
        record["paragraphs"] = ["in": "a shape not known"]
        record["folderID"] = folder.uuidString
        record["removed"] = 0
    }
    defer { try? FileManager.default.removeItem(at: history) }
    try HistoryStore.writeFolders([TranscriptFolder(id: folder, name: "Made up")], in: history)

    let model = AppModel(history: history)

    #expect(!model.holdsTranscripts(folder))
    try model.removeFolder(folder)
    #expect(model.folders.isEmpty)
}

/// A library that cannot be listed says that, not what follows from it.
@MainActor
@Test func aLibraryThatCannotBeListedSaysSo() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("not a folder".utf8).write(to: history)
    defer { try? FileManager.default.removeItem(at: history) }

    let model = AppModel(history: history)

    #expect(model.libraryWarning?.contains("could not be opened") == true)
    #expect(model.entries.isEmpty)
}

/// The name of the key and of each warning are what a record holds. A name from
/// a later version does not stop it opening, and a dismissal does not raise the
/// format: an earlier version that loses it only shows the warning again.
@Test func aDismissalIsReadFromWhatARecordHolds() throws {
    let name = "entry-0.4.0.json"
    var record = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: records.appending(path: name)))
            as? [String: Any])
    record["dismissedWarnings"] = ["gaps", "later"]
    let entry = try JSONDecoder().decode(
        Entry.self, from: JSONSerialization.data(withJSONObject: record))
    #expect(entry.isDismissed(.gaps))
    #expect(!entry.isDismissed(.resumed))
    #expect(entry.dismissedWarnings == ["gaps", "later"])
    #expect(entry.requires == nil)
}
