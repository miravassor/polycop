// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

private let formats = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats")

/// A temporary workspace with its own history, glossaries, playback copies and
/// a copy of `fixture` ready to transcribe or import.
private struct Workspace {
    let root: URL
    let recording: URL
    let history: URL
    let glossaries: URL
    let copies: URL

    init(_ fixture: String) throws {
        root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        history = root.appending(path: "History")
        glossaries = root.appending(path: "Glossaries")
        copies = root.appending(path: "Copies")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        recording = root.appending(path: fixture)
        try FileManager.default.copyItem(at: formats.appending(path: fixture), to: recording)
    }

    @MainActor
    func makeModel() -> AppModel {
        AppModel(
            history: history, glossaries: glossaries, playbackCopies: copies,
            engines: Opener(ScriptedEngine()).engines, defaults: MemoryDefaults())
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func waitUntilIdle(_ model: AppModel) async throws {
    for _ in 0..<2000 where model.hasWork || model.stage.isBusy {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.hasWork && !model.stage.isBusy)
}

@MainActor
private func transcribeOne(_ model: AppModel, _ recording: URL) async throws -> Entry {
    let before = Set(model.entries.map(\.id))
    model.transcribe([recording])
    model.start()
    try await waitUntilIdle(model)
    return try #require(model.entries.first { !before.contains($0.id) })
}

/// Gives `id` every piece of state a reader can accumulate on a transcript:
/// a folder, a correction, a review mark, dismissed warnings, a reading and
/// playback place, an export on disk, a glossary warning and an entry failure.
@MainActor
private func customize(_ model: AppModel, _ id: Entry.ID, in root: URL) async throws -> UUID {
    let folder = try model.createFolder(named: "Psychologie")
    model.moveEntry(id, to: folder)
    model.edit(id, paragraphAt: 0, text: "Texte corrigé par l'étudiant.")
    model.toggleReview(id, paragraphAt: 0)
    model.setDismissed([.glossary, .credits], true, on: id)
    model.export(id, to: root.appending(path: "export.txt"))
    model.updateEntry(id) {
        $0.glossaryWarning = "Glossaire tronqué."
        $0.readingParagraph = 1
        $0.playbackPosition = 1.75
    }
    model.entryFailure = AppModel.EntryFailure(id: id, message: "Échec précédent.")
    model.savePending()
    await model.finishWrites()
    return folder
}

@MainActor
private func expectCleanTranscript(
    _ entry: Entry, in model: AppModel, distinctFrom previous: Entry
) {
    #expect(entry.id != previous.id)
    #expect(entry.state == .finished)
    #expect(!entry.paragraphs.isEmpty)
    #expect(entry.paragraphs == entry.originalParagraphs)
    #expect(entry.paragraphs != previous.paragraphs)
    #expect(!entry.isEdited)
    #expect(entry.folderID == nil)
    #expect(entry.reviewMarks == nil)
    #expect(entry.dismissedWarnings == nil)
    #expect(entry.glossaryWarning == nil)
    #expect(entry.readingParagraph == nil)
    #expect(entry.playbackPosition == nil)
    #expect(entry.saved.isEmpty)
    #expect(entry.savedDigests.isEmpty)
    #expect(!entry.isSaved)
    #expect(entry.removed == nil)
    #expect(!model.canUndo(entry.id))
    #expect(model.failure(for: entry.id) == nil)
}

/// Transcribing the same audio or video file again starts with a fresh entry
/// whether the earlier transcript is still in the library, waiting in Recently
/// Deleted, or deleted for good.
@MainActor
@Test(arguments: ["clip.wav", "clip-video.mp4"])
func transcribingARecordingAgainInheritsNoPriorOrDeletedState(fixture: String) async throws {
    let workspace = try Workspace(fixture)
    defer { workspace.cleanUp() }
    let model = workspace.makeModel()

    let first = try await transcribeOne(model, workspace.recording)
    let folder = try await customize(model, first.id, in: workspace.root)
    let customizedFirst = try #require(model.entry(first.id))

    // While the first transcript is active under the recording's default name,
    // the second gets a numbered title and none of the first transcript's state.
    let second = try await transcribeOne(model, workspace.recording)
    expectCleanTranscript(second, in: model, distinctFrom: customizedFirst)
    #expect(second.title != nil && second.name != customizedFirst.name)
    #expect(model.entry(first.id)?.folderID == folder)
    #expect(model.canUndo(first.id))

    // Once the earlier transcripts are in Recently Deleted, their names and
    // edits no longer force a numbered title or leak into a new transcription.
    model.removeEntry(first.id)
    model.removeEntry(second.id)
    #expect(model.entries.isEmpty && model.recentlyDeleted.count == 2)
    let third = try await transcribeOne(model, workspace.recording)
    expectCleanTranscript(third, in: model, distinctFrom: customizedFirst)
    #expect(third.title == nil && third.name == workspace.recording.lastPathComponent)

    // Deleting the earlier transcripts for good leaves the new one intact and
    // lets the next transcription of the same file start clean as well.
    model.deleteEntry(first.id)
    model.deleteEntry(second.id)
    model.removeEntry(third.id)
    model.deleteEntry(third.id)
    #expect(model.entries.isEmpty && model.recentlyDeleted.isEmpty)
    let fourth = try await transcribeOne(model, workspace.recording)
    expectCleanTranscript(fourth, in: model, distinctFrom: customizedFirst)
    #expect(fourth.title == nil && fourth.name == workspace.recording.lastPathComponent)

    await model.shutDown()
    let reloaded = HistoryStore.all(in: workspace.history).entries
    #expect(reloaded.map(\.id) == [fourth.id])
}

/// Importing a transcript attached to an audio or video recording already used
/// by an active, removed or permanently deleted transcript shares no state with
/// it, and editing or deleting one leaves the other untouched.
@MainActor
@Test(arguments: ["clip.wav", "clip-video.mp4"])
func importingWithAReusedRecordingInheritsNoPriorOrDeletedState(fixture: String) async throws {
    let workspace = try Workspace(fixture)
    defer { workspace.cleanUp() }
    let srt = workspace.root.appending(path: "Notes.srt")
    try Data("1\n00:00:00,000 --> 00:00:01,000\nBonjour à tous.\n".utf8).write(to: srt)
    let model = workspace.makeModel()

    try await model.importTranscript(srt, audio: workspace.recording)
    let first = try #require(model.entries.first)
    _ = try await customize(model, first.id, in: workspace.root)
    let customizedFirst = try #require(model.entry(first.id))

    // A second import with the same recording and transcript file while the
    // first is active gets a fresh identifier, a free name and clean state.
    try await model.importTranscript(srt, audio: workspace.recording)
    let second = try #require(model.entries.first { $0.id != first.id })
    expectCleanTranscript(second, in: model, distinctFrom: customizedFirst)
    #expect(second.name == "Notes (2)")

    // Moving the first to Recently Deleted and importing again reuses the base
    // name rather than colliding with Recently Deleted, and stays clean.
    model.removeEntry(first.id)
    model.removeEntry(second.id)
    try await model.importTranscript(srt, audio: workspace.recording)
    let third = try #require(model.entries.first)
    expectCleanTranscript(third, in: model, distinctFrom: customizedFirst)
    #expect(third.name == "Notes")

    // Permanently deleting the removed transcripts leaves the new import intact
    // on disk and allows another clean import with the same recording.
    model.deleteEntry(first.id)
    model.deleteEntry(second.id)
    await model.finishWrites()
    #expect(HistoryStore.all(in: workspace.history).entries.map(\.id) == [third.id])
    await model.shutDown()
}

/// A decoded playback copy is shared safely while two transcripts use the same
/// recording, survives deleting one of them, and is replaced when the recording
/// file on disk is modified at the same path.
@MainActor
@Test func playbackCopiesSurviveDeletingAnEntryAndRefreshWhenTheFileChanges() async throws {
    let workspace = try Workspace("clip.ogg")
    defer { workspace.cleanUp() }
    let model = workspace.makeModel()
    defer { model.player.discardCopy() }

    let first = try await transcribeOne(model, workspace.recording)
    let second = try await transcribeOne(model, workspace.recording)
    model.replay(first.id, from: 0, leadIn: 0)
    for _ in 0..<100 where !(model.player.isOpen && model.player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(model.player.isOpen)
    model.player.stop()
    let initialCopy = try #require(model.player.keptCopy)
    #expect(FileManager.default.fileExists(atPath: initialCopy.file.path(percentEncoded: false)))

    // Permanently deleting the first transcript leaves the recording and its
    // decoded copy playable for the second transcript.
    model.removeEntry(first.id)
    model.deleteEntry(first.id)
    model.replay(second.id, from: 0, leadIn: 0)
    for _ in 0..<100 where !(model.player.isOpen && model.player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(model.player.isOpen)
    model.player.stop()
    #expect(model.player.keptCopy == initialCopy)

    // Modifying the recording file at the same path updates its modification
    // date, so playback discards the stale decoded copy and decodes anew.
    try Data(contentsOf: formats.appending(path: "clip.ogg")).write(to: workspace.recording)
    try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(10)],
        ofItemAtPath: workspace.recording.path(percentEncoded: false))
    model.replay(second.id, from: 0, leadIn: 0)
    for _ in 0..<100 where !(model.player.isOpen && model.player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(model.player.isOpen)
    model.player.stop()
    let refreshedCopy = try #require(model.player.keptCopy)
    #expect(refreshedCopy.file != initialCopy.file)
    #expect(!FileManager.default.fileExists(atPath: initialCopy.file.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: refreshedCopy.file.path(percentEncoded: false)))
    await model.shutDown()
}
