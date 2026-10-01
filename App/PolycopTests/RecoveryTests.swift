// SPDX-License-Identifier: GPL-3.0-or-later
// Every test of one subject, kept together.
// swiftlint:disable file_length

import Foundation
import Testing

@testable import Polycop

// Tests for failures that originate outside the app: a shared prerequisite
// that never arrives, a record it cannot read, a folder dropped instead of a
// recording, an export changed by another application. None of these may cost
// the user a transcript or be reported as a failure of the recording itself.

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats/clip.wav")

/// A folder with a copy of the clip and a history beside it.
private func library(_ name: String = "cours.wav") throws -> (folder: URL, recording: URL) {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let recording = folder.appending(path: name)
    try FileManager.default.copyItem(at: clip, to: recording)
    return (folder, recording)
}

@MainActor
private func finished(_ recording: URL, in history: URL, model: String, language: String = "fr")
    throws -> Entry
{
    var entry = Entry(
        recording: recording, modelFile: model, glossary: nil, skipsSilence: true,
        subtitles: false, language: language)
    entry.publish([Segment(start: 0, end: 4, text: "Le cours porte sur Freud.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    return entry
}

// MARK: The model a queue is waiting for

/// A recording waits for a model that is not installed yet rather than
/// failing, since the model can still arrive later.
@MainActor
@Test func recordingsWaitForAModelRatherThanFailingWithIt() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    let reading = AppModel(history: history)
    // A catalogue model that is not installed, so nothing is downloaded here.
    let wanted = try #require(ModelCatalog.all.first { !reading.isInstalled($0.id) })
    var entry = Entry(
        recording: recording, modelFile: wanted.id, glossary: nil, skipsSilence: false,
        subtitles: false)
    entry.state = .stopped
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)

    model.retry(entry.id)

    let again = try #require(model.entries.first)
    #expect(again.state == .waiting)
    #expect(model.missingModel?.id == wanted.id)
    #expect(model.isNeeded(wanted.id))
    #expect(model.stage == .waiting)
}

/// Deleting the weights a queued recording needs would make it fail later, so
/// the button offering it is turned off and the call refuses. A model that
/// only a finished transcript names can be deleted, since nothing is waiting
/// for it.
@MainActor
@Test func aModelAQueuedRecordingNeedsIsNotDeleted() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    let reading = AppModel(history: history)
    let wanted = try #require(ModelCatalog.all.first { !reading.isInstalled($0.id) })
    var stopped = Entry(
        recording: recording, modelFile: wanted.id, glossary: nil, skipsSilence: false,
        subtitles: false)
    stopped.state = .stopped
    try HistoryStore.write(stopped, in: history)
    let done = try finished(recording, in: history, model: "ggml-other.bin")
    let model = AppModel(history: history)

    #expect(!model.isNeeded(wanted.id))
    model.retry(stopped.id)

    #expect(model.isNeeded(wanted.id))
    #expect(!model.isNeeded(done.modelFile))
    model.delete(wanted)
    #expect(model.failure != nil)
}

// MARK: Retrying

/// A retry repeats the job that was given, not the one the page shows now.
@MainActor
@Test func retryingKeepsTheSettingsTheRecordingWasGiven() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    var entry = Entry(
        recording: recording, modelFile: "ggml-chosen-then.bin", glossary: nil, skipsSilence: true,
        subtitles: false, language: "en")
    entry.state = .failed("something went wrong")
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    // Everything on the page changes after the recording was added.
    model.selected = ModelCatalog.recommended.id
    model.language = "fr"
    model.skipsSilence = false

    model.retry(entry.id)

    let again = try #require(model.entries.first)
    #expect(again.id != entry.id)
    #expect(again.modelFile == "ggml-chosen-then.bin")
    #expect(again.language == "en")
    #expect(again.skipsSilence)
    #expect(again.paragraphs.isEmpty)
    // The failed attempt stays in the library beside it.
    #expect(model.entry(entry.id)?.state == .failed("something went wrong"))
}

// MARK: What crosses the boundary of the window

/// A folder dropped from the Finder is a file URL too, and must not become a
/// library entry that is bound to fail when ffmpeg opens it.
@MainActor
@Test func aFolderDroppedOnTheWindowIsRefused() throws {
    let (folder, _) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    let model = AppModel(history: history)
    let directory = folder.appending(path: "Dossier")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    model.transcribe([directory])

    #expect(model.entries.isEmpty)
    #expect(model.failure != nil)
}

/// A file with a picture and no sound is not a damaged file, and says so.
@Test func aRecordingWithNoSoundSaysSoRatherThanReadingAsDamaged() async throws {
    let silent = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/formats/clip-silent.mp4")

    await #expect(throws: AudioError.noAudioTrack(silent)) {
        _ = try await AudioDecoder.samples(of: silent)
    }
}

// MARK: Records that cannot be read

/// One damaged record hides nothing else, is left where it is, and is counted.
@Test func aDamagedRecordIsReportedAndLeftAlone() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: history) }
    let entry = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    try HistoryStore.write(entry, in: history)
    let damaged = history.appending(path: UUID().uuidString + ".json")
    try Data("{ pas du JSON".utf8).write(to: damaged)

    let library = HistoryStore.all(in: history)

    #expect(library.entries.map(\.id) == [entry.id])
    #expect(library.damaged == [damaged.lastPathComponent])
    #expect(FileManager.default.fileExists(atPath: damaged.path(percentEncoded: false)))
}

/// The log says which check a damaged record failed, in words that hold none
/// of its text.
@Test func aDamagedRecordSaysWhichCheckItFailed() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: ModelCatalog.recommended.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 4, text: "Texte du cours.")], partial: false)
    let written = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    func reason(_ change: (inout [String: Any]) -> Void, named name: String? = nil) throws
        -> String?
    {
        var record = written
        change(&record)
        let file = history.appending(path: (name ?? entry.id.uuidString) + ".json")
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        guard case .failure(let damage) = HistoryStore.record(file) else { return nil }
        return damage.reason
    }

    #expect(try reason { _ in } == nil)
    #expect(try reason { $0["modelFile"] = nil } == "modelFile is missing")
    #expect(try reason { $0["duration"] = "long" } == "duration has the wrong type")
    #expect(
        try reason({ _ in }, named: UUID().uuidString) == "its id differs from the file name")
    #expect(try reason { $0["duration"] = -1 } == "a time or a path is out of bounds")
    // A segment's path is named by its keys and index, never by its text.
    #expect(
        try reason { $0["decoded"] = [["text": "Texte du cours."]] }
            == "decoded.Index 0.start is missing")
}

/// The list of folders is not a transcript, and is never counted as one.
@Test func theListOfFoldersIsNotReadAsATranscript() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: history) }
    try HistoryStore.writeFolders([TranscriptFolder(id: UUID(), name: "Psychologie")], in: history)

    let library = HistoryStore.all(in: history)

    #expect(library.entries.isEmpty)
    #expect(library.damaged.isEmpty)
}

/// An unreadable folder list must not be treated as an empty one, since the
/// next folder created would then overwrite the only copy of the names.
@MainActor
@Test func aDamagedFolderListBlocksFolderWritesInsteadOfReplacingIt() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: history) }
    let file = history.appending(path: "folders.json")
    try Data("[{\"id\":\"pas un identifiant\"".utf8).write(to: file)

    #expect(throws: (any Error).self) { _ = try HistoryStore.folders(in: history) }

    let model = AppModel(history: history)
    #expect(model.foldersAreDamaged)
    #expect(model.libraryWarning != nil)
    #expect(throws: (any Error).self) { try model.createFolder(named: "Psychologie") }
    #expect(try String(contentsOf: file, encoding: .utf8) == "[{\"id\":\"pas un identifiant\"")
}

/// With the folder list unreadable, no folder can be named, and taking a
/// transcript out of its folder would lose where it was once the list is
/// repaired.
@MainActor
@Test func aDamagedFolderListKeepsEachTranscriptInItsFolder() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: history) }
    let folder = UUID()
    var filed = Entry(
        recording: history.appending(path: "cours.wav"), modelFile: ModelCatalog.turbo.id,
        glossary: nil, skipsSilence: false, subtitles: false)
    filed.state = .finished
    filed.folderID = folder
    try HistoryStore.write(filed, in: history)
    try Data("[{\"id\":\"pas un identifiant\"".utf8).write(
        to: history.appending(path: "folders.json"))
    let model = AppModel(history: history)

    model.moveEntry(filed.id, to: nil)
    #expect(!model.moveEntries([filed.id.uuidString], to: nil))

    #expect(model.entry(filed.id)?.folderID == folder)
    #expect(HistoryStore.all(in: history).entries.first?.folderID == folder)
}

// MARK: Exports the application does not own

/// Turning subtitles on changes which files an export is, so the update has no
/// target of its own and the user is asked where to put them.
@MainActor
@Test func changingTheFormatsAsksWhereToExportAgain() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    let entry = try finished(recording, in: history, model: ModelCatalog.turbo.id)
    let model = AppModel(history: history)

    model.export(entry.id, to: folder.appending(path: "cours.txt"))
    #expect(model.exportState(of: try #require(model.entry(entry.id))) == .current)

    model.setSubtitles(true, for: entry.id)

    #expect(model.exportState(of: try #require(model.entry(entry.id))) == .none)
    model.export(entry.id, to: folder.appending(path: "cours.txt"))
    #expect(
        model.entry(entry.id)?.saved.map(\.lastPathComponent) == ["cours.txt", "cours.srt"])
    #expect(model.exportState(of: try #require(model.entry(entry.id))) == .current)
}

/// A glossary deleted in the Finder is gone from the choice as well. The
/// recordings are transcribed without it, and are not left to look as though
/// they had one.
@MainActor
@Test func aGlossaryDeletedElsewhereIsReportedRatherThanDroppedQuietly() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(history: folder.appending(path: "History"))
    // A Whisper model, since only Whisper is given a glossary.
    model.selected = ModelCatalog.turbo.id
    model.glossaryName = "Un glossaire qui n'existe plus"

    model.transcribe([recording])

    #expect(model.entries.first?.glossary == nil)
    #expect(model.entries.first?.prompt == nil)
    #expect(model.failure?.contains("Un glossaire qui n'existe plus") == true)
    #expect(model.glossaryName == nil)
}

// MARK: Settings that follow the page until the work starts

/// A recording that has not started yet takes the settings shown when Start
/// is pressed, not the ones shown when it was added. One that has already run
/// keeps the settings it was actually given.
@Test func onlyARecordingThatHasNotStartedTakesNewSettings() throws {
    let glossary = Glossary(name: "Psychologie", text: "Freud\nPiaget")
    var planned = Entry(
        recording: URL(filePath: "/tmp/cours.wav"), modelFile: "ggml-first.bin", glossary: nil,
        skipsSilence: false, subtitles: false, language: "fr")
    var done = planned
    done.state = .finished

    planned.adopt(
        modelFile: "ggml-second.bin", glossary: glossary, language: "en", skipsSilence: true)
    done.adopt(
        modelFile: "ggml-second.bin", glossary: glossary, language: "en", skipsSilence: true)

    #expect(planned.modelFile == "ggml-second.bin")
    #expect(planned.glossary == "Psychologie")
    #expect(planned.prompt == glossary.prompt(in: "en"))
    #expect(planned.language == "en")
    #expect(planned.skipsSilence)
    #expect(done.modelFile == "ggml-first.bin")
    #expect(done.glossary == nil)
    #expect(done.language == "fr")
}

// MARK: Two recordings under one name

/// The same lecture added twice, or two files of the same name from different
/// folders, are two transcripts. They are told apart by name, so the list and
/// the save panel do not offer the same thing twice, and correcting one leaves
/// the other alone.
@MainActor
@Test func recordingsOfTheSameNameAreTwoTranscriptsToldApart() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let elsewhere = folder.appending(path: "Autre dossier")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let sameName = elsewhere.appending(path: "cours.wav")
    try FileManager.default.copyItem(at: recording, to: sameName)
    let model = AppModel(history: folder.appending(path: "History"))

    model.transcribe([recording, sameName, recording])

    #expect(model.entries.count == 3)
    #expect(Set(model.entries.map(\.name)).count == 3)
    #expect(Set(model.entries.map(\.id)).count == 3)
    #expect(model.entries.map(\.name).sorted() == ["cours (2).wav", "cours (3).wav", "cours.wav"])
    // Adding leaves the page where the queue and the settings are.
    #expect(model.pane == .new)

    // Corrections belong to one transcript, never to the other.
    let first = try #require(model.entries.last)
    var published = first
    published.publish([Segment(start: 0, end: 2, text: "Le cours.")], partial: false)
    published.state = .finished
    try HistoryStore.write(published, in: folder.appending(path: "History"))
    let reopened = AppModel(history: folder.appending(path: "History"))
    reopened.edit(published.id, paragraphAt: 0, text: "Le cours corrigé.")

    #expect(reopened.entry(published.id)?.paragraphs.first?.text == "Le cours corrigé.")
    #expect(reopened.entries.filter { $0.isEdited }.count == 1)
}

/// Recordings that have not started can be taken back out in one go.
@MainActor
@Test func clearingTheQueueLeavesOnlyWhatWasTranscribed() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    let done = try finished(recording, in: history, model: ModelCatalog.recommended.id)
    let model = AppModel(history: history)
    model.transcribe([recording, recording])
    #expect(model.waiting.count == 2)

    model.clearQueue()

    #expect(model.waiting.isEmpty)
    #expect(model.entries.map(\.id) == [done.id])
    #expect(HistoryStore.all(in: history).entries.map(\.id) == [done.id])
}

// MARK: Several transcripts at once

/// Filing and removing several transcripts together. The one being worked on
/// is never removed while it is running, and the user is told why it stayed.
@MainActor
@Test func actingOnSeveralTranscriptsLeavesTheOneAtWorkAlone() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    let first = try finished(recording, in: history, model: ModelCatalog.recommended.id)
    let second = try finished(recording, in: history, model: ModelCatalog.recommended.id)
    let third = try finished(recording, in: history, model: ModelCatalog.recommended.id)
    let model = AppModel(history: history)
    let course = try model.createFolder(named: "Psychologie")

    // A drag of several rows carries their identifiers together.
    let dragged = [first, second].map(\.id.uuidString).joined(separator: "\n")
    let carried = dragged.split(separator: "\n").map(String.init)
    #expect(model.moveEntries(carried, to: course))
    #expect(model.entry(first.id)?.folderID == course)
    #expect(model.entry(second.id)?.folderID == course)
    #expect(model.entry(third.id)?.folderID == nil)

    // And out again, onto the unfiled section.
    #expect(model.moveEntries(carried, to: nil))
    #expect(model.entries.allSatisfy { $0.folderID == nil })

    model.removeEntries([first.id, third.id])

    #expect(model.entries.map(\.id) == [second.id])
    #expect(HistoryStore.all(in: history).entries.map(\.id) == [second.id])
    #expect(model.failure == nil)
}

@MainActor
@Test func retryingStorageDoesNotStartAnUnscheduledRecording() async throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(history: folder.appending(path: "History"))
    model.transcribe([recording])
    #expect(model.retrySavingHistory())
    #expect(model.running == nil)
    #expect(model.entries.first?.state == .waiting)
    await model.shutDown()
}

@MainActor
@Test func anImportFinishingDoesNotStartAnUnscheduledRecording() async throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(history: folder.appending(path: "History"))
    model.transcribe([recording])
    model.importModel(recording)
    for _ in 0..<200 where model.stage.isBusy {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.stage == .waiting)
    #expect(model.running == nil)
    #expect(model.entries.first?.state == .waiting)
    await model.shutDown()
}

@MainActor
@Test func qwenDoesNotExportSubtitlesFromALegacyFlag() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    var entry = try finished(recording, in: history, model: ModelCatalog.qwen.id)
    entry.subtitles = true
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    model.export(entry.id, to: folder.appending(path: "result.txt"))
    #expect(model.entry(entry.id)?.saved.map(\.pathExtension) == ["txt"])
    model.setSubtitles(true, for: entry.id)
    #expect(model.entry(entry.id)?.subtitles == false)
}

@MainActor
@Test func anUnreadableFolderFileIsNotAnEmptyLibrary() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "folders.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let model = AppModel(history: root)
    #expect(model.foldersAreDamaged)
    #expect(throws: CocoaError.self) { try model.createFolder(named: "Course") }
    #expect(try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
}

@Test func mismatchedRecordIdentityIsLeftUntouched() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = Entry(
        recording: URL(filePath: "/tmp/course.wav"), modelFile: "test",
        glossary: nil, skipsSilence: false, subtitles: false)
    try HistoryStore.write(entry, in: root)
    let wrong = root.appending(path: UUID().uuidString + ".json")
    try FileManager.default.moveItem(
        at: root.appending(path: entry.id.uuidString + ".json"), to: wrong)
    let library = HistoryStore.all(in: root)
    #expect(library.entries.isEmpty)
    #expect(library.damaged == [wrong.lastPathComponent])
    #expect(try JSONDecoder().decode(Entry.self, from: Data(contentsOf: wrong)) == entry)
}

@Test func invalidHistoryTimesAreRejectedWithoutRendering() {
    var entry = Entry(
        recording: URL(filePath: "/tmp/course.wav"), modelFile: "test",
        glossary: nil, skipsSilence: false, subtitles: false)
    entry.decoded = [Segment(start: 0, end: 1e300, text: "Synthetic")]
    #expect(!entry.hasValidHistory)
    entry.decoded = []
    entry.paragraphs = [.init(start: Int.max, text: "Synthetic")]
    #expect(!entry.hasValidHistory)
}

@Test func duplicateFolderIdentifiersAreRejected() throws {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = TranscriptFolder(id: UUID(), name: "Synthetic")
    try HistoryStore.writeFolders([folder, folder], in: root)
    #expect(throws: CocoaError.self) { try HistoryStore.folders(in: root) }
}

@MainActor
@Test func anUnsavedGlossarySurvivesRefreshAndBlocksSilentQuit() {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(history: root, glossaries: root)
    let glossary = Glossary(name: "Invalid/name", text: "Synthetic unsaved correction")
    #expect(throws: CocoaError.self) { try model.saveGlossary(glossary) }
    #expect(model.hasUnsavedHistory)
    model.refreshGlossaries()
    #expect(model.glossaries.contains(glossary))
    #expect(!model.retrySavingHistory())
    #expect(model.storageFailure != nil)
}
