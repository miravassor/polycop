// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// A library in a temporary folder, as the app lays it out.
private struct Library {
    let root = URL.temporaryDirectory.appending(path: "Polycop \(UUID().uuidString)")

    var history: URL { root.appending(path: "History") }
    var glossaries: URL { root.appending(path: "Glossaries") }
    var models: URL { root.appending(path: "Models") }
    var snapshots: URL { root.appending(path: "Snapshots") }

    func clear() { try? FileManager.default.removeItem(at: root) }

    /// The copies, oldest first, by what is visible in the folder.
    func copies() throws -> [String] {
        guard FileManager.default.fileExists(atPath: snapshots.path(percentEncoded: false)) else {
            return []
        }
        return try FileManager.default
            .contentsOfDirectory(atPath: snapshots.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    @discardableResult
    func write(_ name: String) throws -> Entry {
        var entry = Entry(
            recording: root.appending(path: "\(name).wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        entry.title = name
        try HistoryStore.write(entry, in: history)
        return entry
    }
}

private func day(_ number: Int) -> Date {
    Date(timeIntervalSinceReferenceDate: 86400 * Double(number))
}

@Test func aNewVersionKeepsTheLibraryAsItWasAndNotTheModels() throws {
    let library = Library()
    defer { library.clear() }
    let entry = try library.write("Before")
    try GlossaryStore.save(Glossary(name: "Course", text: "term"), in: library.glossaries)
    try FileManager.default.createDirectory(at: library.models, withIntermediateDirectories: true)
    try Data("weights".utf8).write(to: library.models.appending(path: "model.bin"))

    LibrarySnapshots.take(before: "0.5.0", in: library.root)

    let copy = try #require(try library.copies().first)
    #expect(copy.hasSuffix("before 0.5.0"))
    let kept = library.snapshots.appending(path: copy)
    #expect(HistoryStore.all(in: kept.appending(path: "History")).entries.map(\.id) == [entry.id])
    let glossaries = GlossaryStore.all(in: kept.appending(path: "Glossaries")).glossaries
    #expect(glossaries.map(\.text) == ["term"])
    #expect(
        !FileManager.default.fileExists(
            atPath: kept.appending(path: "Models").path(percentEncoded: false)))

    // What the new version then writes does not reach the copy.
    var edited = entry
    edited.title = "After"
    try HistoryStore.write(edited, in: library.history)
    #expect(HistoryStore.all(in: kept.appending(path: "History")).entries.first?.name == "Before")
    #expect(HistoryStore.all(in: library.history).entries.first?.name == "After")
}

@Test func theSameVersionTakesNoSecondCopy() throws {
    let library = Library()
    defer { library.clear() }
    try library.write("A")
    LibrarySnapshots.take(before: "0.5.0", in: library.root, now: day(1))
    LibrarySnapshots.take(before: "0.5.0", in: library.root, now: day(2))
    #expect(try library.copies().count == 1)
}

@Test func anEmptyLibraryHasNothingToKeepUntilItHolds() throws {
    let library = Library()
    defer { library.clear() }
    try FileManager.default.createDirectory(at: library.history, withIntermediateDirectories: true)
    LibrarySnapshots.take(before: "0.5.0", in: library.root, now: day(1))
    #expect(try library.copies().isEmpty)

    try library.write("A")
    LibrarySnapshots.take(before: "0.5.0", in: library.root, now: day(2))
    #expect(try library.copies().isEmpty)
    LibrarySnapshots.take(before: "0.6.0", in: library.root, now: day(3))
    #expect(try library.copies().count == 1)
}

/// The reason for two: the version that fixes a damaging one copies what it
/// damaged, and the library from before it must still be there.
@Test func theLastGoodLibrarySurvivesTheVersionThatFixesADamagingOne() throws {
    let library = Library()
    defer { library.clear() }
    let entry = try library.write("Good")
    LibrarySnapshots.take(before: "0.4.0", in: library.root, now: day(1))
    LibrarySnapshots.take(before: "0.5.0", in: library.root, now: day(2))
    var damaged = entry
    damaged.title = "Damaged"
    try HistoryStore.write(damaged, in: library.history)
    LibrarySnapshots.take(before: "0.5.1", in: library.root, now: day(3))

    let copies = try library.copies()
    #expect(copies.count == 2)
    #expect(copies[0].hasSuffix("before 0.5.0"))
    #expect(copies[1].hasSuffix("before 0.5.1"))
    let good = library.snapshots.appending(path: copies[0]).appending(path: "History")
    #expect(HistoryStore.all(in: good).entries.first?.name == "Good")
}

@Test func goingBackToAnEarlierVersionKeepsWhatTheLaterOneWrote() throws {
    let library = Library()
    defer { library.clear() }
    try library.write("A")
    LibrarySnapshots.take(before: "0.6.0", in: library.root, now: day(1))
    LibrarySnapshots.take(before: "0.5.0", in: library.root, now: day(2))
    #expect(try library.copies().last?.hasSuffix("before 0.5.0") == true)
}

@Test func aFailedCopyLeavesNoneAndIsTriedAgainAtTheNextLaunch() throws {
    let library = Library()
    defer { library.clear() }
    try library.write("A")
    try GlossaryStore.save(Glossary(name: "Course", text: "term"), in: library.glossaries)
    let path = library.glossaries.appending(path: "Course.txt").path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

    LibrarySnapshots.take(before: "0.5.0", in: library.root, now: day(1))
    #expect(try library.copies().isEmpty)
    #expect(
        !FileManager.default.fileExists(
            atPath: library.snapshots.appending(path: ".partial").path(percentEncoded: false)))

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    LibrarySnapshots.take(before: "0.5.0", in: library.root, now: day(2))
    #expect(try library.copies().count == 1)
}

@Test func aCopyCutShortIsNeitherKeptNorCounted() throws {
    let library = Library()
    defer { library.clear() }
    try library.write("A")
    let partial = library.snapshots.appending(path: ".partial/History")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data("cut short".utf8).write(to: partial.appending(path: "left.json"))

    LibrarySnapshots.take(before: "0.5.0", in: library.root)

    let copy = try #require(try library.copies().first)
    #expect(try library.copies().count == 1)
    let history = library.snapshots.appending(path: copy).appending(path: "History")
    #expect(HistoryStore.all(in: history).entries.count == 1)
    #expect(
        !FileManager.default.fileExists(
            atPath: history.appending(path: "left.json").path(percentEncoded: false)))
}

@Test func aTranscriptDeletedForGoodLeavesEveryCopy() throws {
    let library = Library()
    defer { library.clear() }
    let gone = try library.write("Gone")
    let staying = try library.write("Staying")
    LibrarySnapshots.take(before: "0.4.0", in: library.root, now: day(1))
    LibrarySnapshots.take(before: "0.5.0", in: library.root, now: day(2))
    let added = try library.write("Added after the copies")

    try HistoryStore.delete(gone.id, in: library.history)
    try HistoryStore.delete(added.id, in: library.history)

    for copy in try library.copies() {
        let history = library.snapshots.appending(path: copy).appending(path: "History")
        #expect(HistoryStore.all(in: history).entries.map(\.id) == [staying.id])
    }
}

/// Deleting a glossary puts it in the Trash, which a test must leave alone, so
/// these name one that left the library already: its copies go before the Trash.
@Test func aDeletedGlossaryAndItsCorrectionsLeaveEveryCopy() throws {
    let library = Library()
    defer { library.clear() }
    try GlossaryStore.save(Glossary(name: "Gone", text: "term"), in: library.glossaries)
    try GlossaryStore.save(Glossary(name: "Staying", text: "term"), in: library.glossaries)
    let corrections = library.glossaries.appending(path: "Gone.corrections.json")
    try Data("[]".utf8).write(to: corrections)
    LibrarySnapshots.take(before: "0.5.0", in: library.root)
    let copy = try #require(try library.copies().first)
    try FileManager.default.removeItem(at: library.glossaries.appending(path: "Gone.txt"))
    try FileManager.default.removeItem(at: corrections)

    #expect(throws: (any Error).self) {
        try GlossaryStore.delete(named: "Gone", in: library.glossaries)
    }
    try CourseCorrections.delete(for: "Gone", in: library.glossaries)

    let kept = library.snapshots.appending(path: copy).appending(path: "Glossaries")
    #expect(GlossaryStore.all(in: kept).glossaries.map(\.name) == ["Staying"])
    #expect(
        !FileManager.default.fileExists(
            atPath: kept.appending(path: "Gone.corrections.json").path(percentEncoded: false)))
}

@Test func deletingFromALibraryWithoutCopiesIsNotAFailure() throws {
    let library = Library()
    defer { library.clear() }
    let entry = try library.write("A")
    try HistoryStore.delete(entry.id, in: library.history)
    #expect(HistoryStore.all(in: library.history).entries.isEmpty)
}
