// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import os

@testable import Polycop

// The transcription queue with a scripted engine in place of a model, so these
// run everywhere, CI and its sanitizers included. The engine can hold after a
// segment, which is where a pause, a stop or quitting finds a real engine.

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats/clip.wav")

private let script = [
    Segment(start: 0, end: 1, text: "Bonjour à tous."),
    Segment(start: 1, end: 2, text: "Nous commençons."),
    Segment(start: 2, end: 3, text: "Voici le plan."),
]

/// Gives the script's segments from where a call starts, as a real engine
/// continues a paused recording, and can hold or fail once at one segment.
nonisolated final class ScriptedEngine: TranscriptionEngine {
    private struct State {
        var holdsAt: Int?
        var failsAt: Int?
        var isHolding = false
        var isReleased = false
        var starts: [TimeInterval] = []
        var drains = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(holdsAt: Int? = nil, failsAt: Int? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(holdsAt: holdsAt, failsAt: failsAt))
    }

    var isHolding: Bool { state.withLock { $0.isHolding } }
    var starts: [TimeInterval] { state.withLock { $0.starts } }
    var drains: Int { state.withLock { $0.drains } }
    func release() { state.withLock { $0.isReleased = true } }

    func transcribe(
        samples: [Float], settings: DecodingSettings, from start: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void,
        onSegment: @escaping @Sendable (Segment) -> Void
    ) async throws -> [Segment] {
        state.withLock { $0.starts.append(start) }
        var written: [Segment] = []
        for (index, segment) in script.enumerated() where segment.start >= start {
            if state.withLock({ $0.failsAt }) == index {
                state.withLock { $0.failsAt = nil }
                throw TranscriptionError.failed(-1)
            }
            if state.withLock({ $0.holdsAt }) == index {
                state.withLock { $0.isHolding = true }
                defer { state.withLock { $0.holdsAt = nil } }
                while !state.withLock({ $0.isReleased }) {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            try Task.checkCancellation()
            onSegment(segment)
            written.append(segment)
            onProgress(Double(index + 1) / Double(script.count))
        }
        return written
    }

    func drain() async { state.withLock { $0.drains += 1 } }
}

/// Engines that say the models in `installed` are there, the recommended one
/// at first, and open `engine`, counting the openings and failing the first
/// `failures` of them.
@MainActor
private final class Opener {
    let engine: ScriptedEngine
    var failures: Int
    var installed: Set<String> = [ModelCatalog.recommended.id]
    private(set) var opened = 0

    init(_ engine: ScriptedEngine, failures: Int = 0) {
        self.engine = engine
        self.failures = failures
    }

    var engines: Engines {
        Engines(
            installed: { self.installed },
            open: { _, _ in
                self.opened += 1
                if self.failures > 0 {
                    self.failures -= 1
                    throw TranscriptionError.failed(-2)
                }
                return self.engine
            })
    }
}

/// Recordings copied from the clip into a folder of their own, beside the
/// history folder the model is given.
private func recordings(_ count: Int) throws -> (folder: URL, files: [URL]) {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let files = (1...count).map { folder.appending(path: "lecture-\($0).wav") }
    for file in files { try FileManager.default.copyItem(at: clip, to: file) }
    return (folder, files)
}

/// Polls until `condition` holds, for up to about ten seconds.
@MainActor
private func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

@MainActor
private func entry(_ model: AppModel, _ file: URL) throws -> Entry {
    try #require(model.entries.first { $0.name == file.lastPathComponent })
}

@MainActor
@Suite struct TheQueue {
    @Test func runsRecordingsInTurnOnOneEngineAndThenLetsItGo() async throws {
        let (folder, files) = try recordings(2)
        defer { try? FileManager.default.removeItem(at: folder) }
        let opener = Opener(ScriptedEngine())
        let model = AppModel(history: folder.appending(path: "history"), engines: opener.engines)
        model.transcribe(files)
        model.start()
        try await until { !model.hasWork && !model.stage.isBusy }

        for file in files {
            #expect(try entry(model, file).state == .finished)
            #expect(try entry(model, file).decoded == script)
        }
        #expect(opener.opened == 1)
        #expect(model.engine == nil)
        await model.shutDown()
    }

    @Test func aPauseKeepsWhatWasWrittenAndTheResumeContinuesAfterIt() async throws {
        let (folder, files) = try recordings(1)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ScriptedEngine(holdsAt: 1)
        let model = AppModel(
            history: folder.appending(path: "history"), engines: Opener(engine).engines)
        model.transcribe(files)
        model.start()
        try await until { engine.isHolding }

        model.pause()
        try await until {
            if case .paused = model.stage { true } else { false }
        }
        #expect(try entry(model, files[0]).decoded == [script[0]])
        #expect(try entry(model, files[0]).isPartial)

        model.resume()
        try await until { !model.hasWork && !model.stage.isBusy }
        #expect(try entry(model, files[0]).decoded == script)
        #expect(try entry(model, files[0]).state == .finished)
        #expect(try entry(model, files[0]).resumedAt == [script[0].end])
        #expect(engine.starts == [0, script[0].end])
        await model.shutDown()
    }

    @Test func aStopKeepsWhatWasWrittenAndTheNextRecordingRuns() async throws {
        let (folder, files) = try recordings(2)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ScriptedEngine(holdsAt: 1)
        let model = AppModel(
            history: folder.appending(path: "history"), engines: Opener(engine).engines)
        model.transcribe(files)
        model.start()
        try await until { engine.isHolding }

        model.cancel()
        try await until { !model.hasWork && !model.stage.isBusy }
        #expect(try entry(model, files[0]).state == .stopped)
        #expect(try entry(model, files[0]).decoded == [script[0]])
        #expect(try entry(model, files[1]).state == .finished)
        #expect(try entry(model, files[1]).decoded == script)
        await model.shutDown()
    }

    @Test func aFailureKeepsWhatWasWrittenAndTheNextRecordingRuns() async throws {
        let (folder, files) = try recordings(2)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            history: folder.appending(path: "history"),
            engines: Opener(ScriptedEngine(failsAt: 1)).engines)
        model.transcribe(files)
        model.start()
        try await until { !model.hasWork && !model.stage.isBusy }

        guard case .failed = try entry(model, files[0]).state else {
            Issue.record("Expected the first recording to fail")
            return
        }
        #expect(try entry(model, files[0]).decoded == [script[0]])
        #expect(try entry(model, files[0]).isPartial)
        #expect(try entry(model, files[1]).state == .finished)
        await model.shutDown()
    }

    @Test func anEngineThatFailsToOpenFailsOnlyItsRecording() async throws {
        let (folder, files) = try recordings(2)
        defer { try? FileManager.default.removeItem(at: folder) }
        let opener = Opener(ScriptedEngine(), failures: 1)
        let model = AppModel(history: folder.appending(path: "history"), engines: opener.engines)
        model.transcribe(files)
        model.start()
        try await until { !model.hasWork && !model.stage.isBusy }

        guard case .failed = try entry(model, files[0]).state else {
            Issue.record("Expected the first recording to fail")
            return
        }
        #expect(try entry(model, files[1]).state == .finished)
        #expect(opener.opened == 2)
        await model.shutDown()
    }

    /// A retry waits for a model deleted since, and Start, pressed for other
    /// recordings, leaves it the settings of the job it repeats.
    @Test func aRetryWaitingForItsModelKeepsItsSettingsAtStart() async throws {
        let (folder, files) = try recordings(1)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appending(path: "history")
        var failed = Entry(
            recording: files[0], modelFile: ModelCatalog.turboQuantized.id, glossary: nil,
            skipsSilence: false, subtitles: false, language: "en")
        failed.state = .failed("")
        try HistoryStore.write(failed, in: history)
        let opener = Opener(ScriptedEngine())
        let model = AppModel(history: history, engines: opener.engines)

        model.retry(failed.id)
        let retry = try #require(model.waiting.first)
        opener.installed.insert(ModelCatalog.turboQuantized.id)
        model.refreshInstalled()
        model.selected = ModelCatalog.recommended.id
        model.language = "fr"
        model.start()
        try await until { !model.hasWork && !model.stage.isBusy }

        let finished = try #require(model.entry(retry.id))
        #expect(finished.state == .finished)
        #expect(finished.modelFile == ModelCatalog.turboQuantized.id)
        #expect(finished.language == "en")
    }

    @Test func quittingStopsTheRecordingKeepsItsTextAndLetsTheEngineGo() async throws {
        let (folder, files) = try recordings(2)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ScriptedEngine(holdsAt: 1)
        let model = AppModel(
            history: folder.appending(path: "history"), engines: Opener(engine).engines)
        model.transcribe(files)
        model.start()
        try await until { engine.isHolding }

        await model.shutDown()
        #expect(try entry(model, files[0]).state == .stopped)
        #expect(try entry(model, files[0]).decoded == [script[0]])
        #expect(try entry(model, files[1]).state == .stopped)
        #expect(engine.starts.count == 1)
        #expect(engine.drains == 1)
        #expect(model.engine == nil)
    }

    /// A stop still finishing when the app quits must not start the next one.
    @Test func quittingWhileAStopFinishesDoesNotStartTheNextRecording() async throws {
        let (folder, files) = try recordings(2)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ScriptedEngine(holdsAt: 1)
        let model = AppModel(
            history: folder.appending(path: "history"), engines: Opener(engine).engines)
        model.transcribe(files)
        model.start()
        try await until { engine.isHolding }

        model.cancel()
        await model.shutDown()
        #expect(try entry(model, files[1]).state == .stopped)
        #expect(engine.starts.count == 1)
    }
}
