// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

// Tests for files the app does not own moving or disappearing after the fact:
// the recording, a written export, downloaded model weights. The transcript
// itself must survive regardless, since it is the only thing the app owns.

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats/clip.wav")
private let whisperInstalled = ModelStore.isInstalled(ModelCatalog.turbo)

/// A folder with a copy of the clip and a history beside it.
private func library(_ name: String = "cours.wav") throws -> (folder: URL, recording: URL) {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let recording = folder.appending(path: name)
    try FileManager.default.copyItem(at: clip, to: recording)
    return (folder, recording)
}

@MainActor
private func finished(_ recording: URL, in history: URL) throws -> Entry {
    var entry = Entry(
        recording: recording, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 4, text: "Le cours porte sur Freud.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    return entry
}

@MainActor
@Test func aTranscriptOutlivesItsRecording() async throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    let entry = try finished(recording, in: history)
    let model = AppModel(history: history)
    #expect(model.entry(entry.id)?.hasRecording == true)

    try FileManager.default.removeItem(at: recording)

    // The text is still there, and the window can say the recording is not.
    #expect(model.entry(entry.id)?.hasRecording == false)
    #expect(model.entry(entry.id)?.paragraphs.first?.text == "Le cours porte sur Freud.")
    model.replay(entry.id, from: 0)
    for _ in 0..<50 where model.player.failure == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.player.failure != nil)
    #expect(!model.player.isPlaying)
    model.player.stop()
}

@MainActor
@Test func exportingAgainWritesTheFileThatWasDeleted() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    let entry = try finished(recording, in: history)
    let model = AppModel(history: history)

    let destination = folder.appending(path: "cours.txt")
    model.export(entry.id, to: destination)
    let written = try #require(model.entry(entry.id)?.saved.first)
    #expect(FileManager.default.fileExists(atPath: written.path(percentEncoded: false)))
    #expect(model.exportState(of: try #require(model.entry(entry.id))) == .current)

    try FileManager.default.removeItem(at: written)

    // The window no longer claims an export that is not there, and offers to
    // write one again rather than a button that does nothing.
    #expect(model.exportState(of: try #require(model.entry(entry.id))) == .missing)
    model.export(entry.id, to: destination)
    let again = try #require(model.entry(entry.id)?.saved.first)
    #expect(FileManager.default.fileExists(atPath: again.path(percentEncoded: false)))
    #expect(model.failure(for: entry.id) == nil)
    #expect(model.exportState(of: try #require(model.entry(entry.id))) == .current)
}

@MainActor
@Test func exportingIntoAFolderThatIsGoneSaysSo() throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    let entry = try finished(recording, in: history)
    let model = AppModel(history: history)
    let gone = folder.appending(path: "Elsewhere")

    model.export(entry.id, to: gone.appending(path: "cours.txt"))

    #expect(model.failure(for: entry.id) != nil)
    #expect(model.entry(entry.id)?.isSaved != true)
    #expect(model.entry(entry.id)?.saved.isEmpty == true)
}

@MainActor
@Test(.enabled(if: whisperInstalled))
func repairingWithoutTheRecordingLeavesTheTranscriptAlone() async throws {
    let (folder, recording) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = folder.appending(path: "History")
    var entry = Entry(
        recording: recording, modelFile: ModelCatalog.turbo.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.publish(
        (0..<12).map {
            Segment(start: Double($0) * 0.25, end: Double($0) * 0.25 + 0.25, text: " Merci.")
        }, partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    try FileManager.default.removeItem(at: recording)

    model.repairRepeats(entry.id)
    for _ in 0..<200 where model.stage.isBusy {
        try await Task.sleep(for: .milliseconds(50))
    }

    let after = try #require(model.entry(entry.id))
    #expect(after.state == .finished)
    #expect(after.paragraphs.first?.text.contains("Merci") == true)
    #expect(model.failure(for: entry.id) != nil)
    await model.shutDown()
}

/// The two failures a user can act on read differently: a file that is gone
/// says where it was, a file that cannot be read names itself.
@Test func aMissingRecordingReadsDifferentlyFromAnUnreadableOne() async throws {
    let gone = URL.temporaryDirectory.appending(path: "\(UUID().uuidString)/cours.wav")
    let remote = try #require(URL(string: "https://example.com/cours.wav"))

    await #expect(throws: AudioError.missing(gone)) { _ = try await AudioDecoder.samples(of: gone) }
    await #expect(throws: AudioError.self) { _ = try await AudioDecoder.samples(of: remote) }
    #expect(
        AudioError.missing(gone).errorDescription?.contains("no longer where it was") == true)
}
