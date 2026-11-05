// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats/clip.wav")

/// A job held after its first segment with its progress saved, which is where
/// a crash finds it: another model opening the same folder is the next launch.
@MainActor
private struct HeldJob {
    let folder: URL
    let history: URL
    let engine: ScriptedEngine
    let model: AppModel
    let id: Entry.ID

    init() async throws {
        folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        history = folder.appending(path: "History")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = folder.appending(path: "lecture.wav")
        try FileManager.default.copyItem(at: clip, to: recording)
        engine = ScriptedEngine(holdsAt: 1)
        model = AppModel(history: history, engines: Opener(engine).engines)
        model.savedProgress.interval = .milliseconds(10)
        model.transcribe([recording])
        id = try #require(model.entries.first).id
        model.start()
        let history = history
        try await until { HistoryStore.all(in: history).entries.first?.decoded.count == 1 }
    }

    var onDisk: Entry? { HistoryStore.all(in: history).entries.first }

    func end() async {
        engine.release()
        await model.shutDown()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Polls until `condition` holds, for up to about ten seconds.
@MainActor
private func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

private func record(
    _ state: Entry.State, decoded: [Segment], published: [Segment] = [], in history: URL
) throws -> Entry {
    var entry = Entry(
        recording: history.appending(path: "lecture.wav"),
        modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
        subtitles: false)
    if !published.isEmpty { entry.publish(published, partial: true) }
    entry.decoded = decoded
    entry.state = state
    try HistoryStore.write(entry, in: history)
    return entry
}

private let first = Segment(start: 0, end: 1, text: "Bonjour à tous.")
private let second = Segment(start: 1, end: 2, text: "Nous commençons.")

@MainActor
@Suite struct SavedProgressOfAJob {
    @Test func aCrashLeavesWhatWasSavedAsTheText() async throws {
        let job = try await HeldJob()
        #expect(job.onDisk?.state == .running)
        let afterTheCrash = AppModel(history: job.history)
        let entry = try #require(afterTheCrash.entry(job.id))
        #expect(entry.state == .stopped)
        #expect(entry.isPartial)
        #expect(entry.paragraphs.map(\.text) == [first.text])
        await afterTheCrash.finishWrites()
        await job.end()
    }

    /// The page shows no notice about a text it does not show yet.
    @Test func thePageStaysAsItIsWhileTheJobRuns() async throws {
        let job = try await HeldJob()
        let entry = try #require(job.model.entry(job.id))
        #expect(entry.decoded.isEmpty)
        #expect(entry.paragraphs.isEmpty)
        await job.end()
    }

    @Test func aRenameDuringTheJobKeepsWhatWasSaved() async throws {
        let job = try await HeldJob()
        job.model.rename(job.id, to: "Renamed")
        await job.model.finishWrites()
        #expect(job.onDisk?.title == "Renamed")
        #expect(job.onDisk?.decoded.count == 1)
        await job.end()
    }

    @Test func theFinishedTextHoldsEachSegmentOnce() async throws {
        let job = try await HeldJob()
        job.engine.release()
        try await until { !job.model.hasWork && !job.model.stage.isBusy }
        await job.model.finishWrites()
        #expect(job.model.entry(job.id)?.decoded.count == 3)
        #expect(job.onDisk?.decoded.count == 3)
        #expect(job.onDisk?.state == .finished)
        #expect(job.onDisk?.isPartial == false)
        await job.end()
    }

    @Test func aPauseThenAResumeHoldEachSegmentOnce() async throws {
        let job = try await HeldJob()
        job.model.pause()
        try await until {
            if case .paused = job.model.stage { true } else { false }
        }
        await job.model.finishWrites()
        #expect(job.onDisk?.decoded.count == 1)
        #expect(job.onDisk?.paragraphs.count == 1)
        job.model.resume()
        try await until { !job.model.hasWork && !job.model.stage.isBusy }
        await job.model.finishWrites()
        #expect(job.onDisk?.decoded.count == 3)
        await job.end()
    }

    @Test func aStopLeavesTheWholeTextOnDisk() async throws {
        let job = try await HeldJob()
        job.model.cancel()
        try await until { !job.model.stage.isBusy }
        await job.model.finishWrites()
        #expect(job.onDisk?.state == .stopped)
        #expect(job.onDisk?.paragraphs.map(\.text) == [first.text])
        await job.end()
    }
}

@MainActor
@Suite struct ARecordFoundAtLaunch {
    private let history = URL.temporaryDirectory.appending(path: UUID().uuidString)

    @Test func aJobWithNothingSavedStopsWithoutText() async throws {
        defer { try? FileManager.default.removeItem(at: history) }
        let saved = try record(.running, decoded: [], in: history)
        let model = AppModel(history: history)
        #expect(model.entry(saved.id)?.state == .stopped)
        #expect(model.entry(saved.id)?.paragraphs.isEmpty == true)
        #expect(model.entry(saved.id)?.isPartial == false)
        await model.finishWrites()
    }

    /// A paused job resumed has paragraphs of what it had at its pause.
    @Test func aResumedJobTakesEverythingItSaved() async throws {
        defer { try? FileManager.default.removeItem(at: history) }
        let saved = try record(
            .running, decoded: [first, second], published: [first], in: history)
        let model = AppModel(history: history)
        let text = model.entry(saved.id)?.paragraphs.map(\.text).joined()
        #expect(text?.contains(second.text) == true)
        await model.finishWrites()
    }

    @Test func aJobForcedToQuitWhileStoppingGetsItsText() async throws {
        defer { try? FileManager.default.removeItem(at: history) }
        let saved = try record(.stopped, decoded: [first], in: history)
        let model = AppModel(history: history)
        #expect(model.entry(saved.id)?.paragraphs.map(\.text) == [first.text])
        await model.finishWrites()
    }

    @Test func aStoppedTranscriptKeepsItsCorrections() async throws {
        defer { try? FileManager.default.removeItem(at: history) }
        var saved = try record(.stopped, decoded: [first], published: [first], in: history)
        saved.edit(paragraphAt: 0, text: "Corrected.")
        try HistoryStore.write(saved, in: history)
        let model = AppModel(history: history)
        #expect(model.entry(saved.id)?.paragraphs.map(\.text) == ["Corrected."])
        #expect(model.entry(saved.id)?.isEdited == true)
        await model.finishWrites()
    }

    @Test func aFinishedTranscriptIsLeftAlone() async throws {
        defer { try? FileManager.default.removeItem(at: history) }
        let saved = try record(.finished, decoded: [first], in: history)
        let model = AppModel(history: history)
        #expect(model.entry(saved.id)?.state == .finished)
        #expect(model.entry(saved.id)?.paragraphs.isEmpty == true)
        await model.finishWrites()
    }
}
