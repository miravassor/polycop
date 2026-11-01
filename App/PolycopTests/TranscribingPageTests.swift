// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

// What the page of a recording offers before and while it is transcribed,
// decided from the queue's state, which these set at once rather than reach by
// running an engine.

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats/clip.wav")

private let other = ModelCatalog.all.first { $0.id != ModelCatalog.recommended.id }

/// Recordings waiting in a library of their own, in the order given, each
/// for the model named beside it.
@MainActor
private func withWaiting(
    _ models: [String], _ body: (AppModel, [Entry.ID]) async throws -> Void
) async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let history = folder.appending(path: "History")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var ids: [Entry.ID] = []
    for (index, modelFile) in models.enumerated() {
        let recording = folder.appending(path: "lecture-\(index + 1).wav")
        try FileManager.default.copyItem(at: clip, to: recording)
        let entry = Entry(
            recording: recording, modelFile: modelFile, glossary: nil, skipsSilence: false,
            subtitles: false, added: Date(timeIntervalSince1970: Double(index)))
        try HistoryStore.write(entry, in: history)
        ids.append(entry.id)
    }
    let model = AppModel(history: history, engines: Opener(ScriptedEngine()).engines)
    try await body(model, ids)
    model.stage = .waiting
    model.running = nil
    await model.shutDown()
}

@MainActor
private func step(_ model: AppModel, _ id: Entry.ID) throws -> WaitingStep? {
    model.waitingStep(for: try #require(model.entry(id)))
}

@MainActor
@Test func aWaitingPageOffersWhatTheQueueAllows() async throws {
    let recommended = ModelCatalog.recommended.id
    try await withWaiting([recommended, recommended]) { model, ids in
        // Nothing runs: Start, which begins both.
        #expect(try step(model, ids[1]) == .start(count: 2))

        let index = try #require(model.entries.firstIndex { $0.id == ids[0] })
        model.entries[index].state = .running
        model.running = ids[0]
        model.stage = .transcribing(0.4)
        // Added while the first runs: it joins when asked.
        #expect(try step(model, ids[1]) == .addToQueue)
        // In line and next: it names the one it follows.
        model.scheduled = [ids[1]]
        #expect(try step(model, ids[1]) == .turn(after: "lecture-1.wav"))
        // A page for what runs is not a waiting page.
        #expect(try step(model, ids[0]) == nil)
    }
}

@MainActor
@Test func aRecordingWaitsForTheModelItNeeds() async throws {
    let other = try #require(other)
    try await withWaiting([ModelCatalog.recommended.id, other.id]) { model, ids in
        model.downloadingModel = other
        model.stage = .downloading(0.3)
        let needing = try #require(model.entry(ids[1]))
        let notNeeding = try #require(model.entry(ids[0]))
        #expect(model.isWaitingForDownload(needing))
        #expect(!model.isWaitingForDownload(notNeeding))
        #expect(model.waitingStep(for: needing) == .download)
        // In line behind a download it does not need, with nothing running.
        model.scheduled = [ids[0]]
        #expect(model.waitingStep(for: notNeeding) == .turn(after: nil))
    }
}

@MainActor
@Test func eachStepOfTheWorkHasOneName() {
    typealias Stage = AppModel.Stage
    #expect(Stage.decoding.title == Stage.loading.title)
    #expect(Stage.loading.line == Stage.loading.title)
    #expect(Stage.transcribing(0.42).line == "\(Stage.transcribing(0.42).title) · \(percent(0.42))")
    #expect(Stage.downloading(0.3).fraction == 0.3)
    #expect(Stage.paused(0.5).fraction == 0.5)
    #expect(Stage.stopping.fraction == nil)
    #expect(Stage.paused(0.5).isPaused && !Stage.transcribing(0.5).isPaused)
}
