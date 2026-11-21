// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import Testing

@testable import Polycop

/// An isolated model with a scripted engine, shut down and cleaned up on exit.
@MainActor
private func withModel(
    _ engine: ScriptedEngine = ScriptedEngine(),
    _ body: (AppModel, URL) async throws -> Void
) async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let model = AppModel(
        history: folder.appending(path: "History"),
        glossaries: folder.appending(path: "Glossaries"),
        models: folder.appending(path: "Models"),
        playbackCopies: folder.appending(path: "Replay"),
        engines: Opener(engine).engines,
        defaults: MemoryDefaults())
    do {
        try await body(model, folder)
    } catch {
        engine.release()
        await model.shutDown()
        try? FileManager.default.removeItem(at: folder)
        throw error
    }
    engine.release()
    await model.shutDown()
    try? FileManager.default.removeItem(at: folder)
}

/// Polls until `condition` holds, for up to about ten seconds.
@MainActor
private func until(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    for _ in 0..<2000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), sourceLocation: sourceLocation)
}

@MainActor
@Test func eachStageOffersTheRightStatusControls() {
    #expect(TranscriptionStatus.controls(for: .transcribing(0.4)) == [.pause, .stop])
    #expect(TranscriptionStatus.controls(for: .paused(0.4)) == [.resume, .stop])
    #expect(TranscriptionStatus.controls(for: .downloading(0.6)) == [.cancelDownload])
    #expect(TranscriptionStatus.controls(for: .loading) == [.stop])
    #expect(TranscriptionStatus.controls(for: .decoding) == [.stop])
    #expect(TranscriptionStatus.controls(for: .repairing(0.5)) == [.stop])
    #expect(TranscriptionStatus.controls(for: .stopping).isEmpty)
    #expect(TranscriptionStatus.controls(for: .waiting).isEmpty)
}

@MainActor
@Test func eachStatusControlHasOneTitleAndSymbol() {
    typealias Control = TranscriptionStatus.Control
    #expect(Control.pause.title == "Pause Transcription")
    #expect(Control.pause.symbol == "pause.circle.fill")
    #expect(Control.resume.title == "Resume Transcription")
    #expect(Control.resume.symbol == "play.circle.fill")
    #expect(Control.stop.title == "Stop Transcription")
    #expect(Control.stop.symbol == "stop.circle.fill")
    #expect(Control.cancelDownload.title == "Cancel Download")
    #expect(Control.cancelDownload.symbol == "xmark.circle.fill")
}

@MainActor
@Test func statusControlsResumePauseAndStopARunningJob() async throws {
    let engine = ScriptedEngine(holdsAt: 0)
    try await withModel(engine) { model, folder in
        var entry = Entry(
            recording: folder.appending(path: "lecture.wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        entry.state = .running
        model.entries = [entry]
        model.running = entry.id
        model.stage = .paused(0.4)
        model.paused = AppModel.Transcription(
            id: entry.id, samples: [Float](repeating: 0, count: 16_000))

        TranscriptionStatus.Control.resume.perform(on: model)
        try await until { engine.isHolding }
        #expect(model.stage.isTranscribing)
        #expect(model.paused == nil)

        TranscriptionStatus.Control.pause.perform(on: model)
        try await until { model.stage.isPaused }
        #expect(model.paused?.id == entry.id)

        TranscriptionStatus.Control.stop.perform(on: model)
        try await until { model.stage == .waiting }
        #expect(model.entry(entry.id)?.state == .stopped)
        #expect(model.running == nil)
        #expect(model.paused == nil)
    }
}

@MainActor
@Test func cancelDownloadControlStopsAnActiveDownload() async throws {
    try await withModel { model, _ in
        model.downloadingModel = ModelCatalog.recommended
        model.stage = .downloading(0.6)

        TranscriptionStatus.Control.cancelDownload.perform(on: model)
        try await until { model.stage == .waiting }
        #expect(model.downloadingModel == nil)
    }
}
