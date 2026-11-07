// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import os

@testable import Polycop

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats/clip.wav")

/// Decides on German when asked to detect, and keeps the language of each call.
/// It can hold in that decision and ignore a stop, as whisper.cpp does.
private nonisolated final class DetectingEngine: TranscriptionEngine {
    private let asked = OSAllocatedUnfairLock(initialState: [String]())
    private let held = OSAllocatedUnfairLock(initialState: (isHolding: false, isReleased: true))
    var languages: [String] { asked.withLock { $0 } }
    var isHolding: Bool { held.withLock { $0.isHolding } }
    func holdInTheDecision() { held.withLock { $0.isReleased = false } }
    func release() { held.withLock { $0.isReleased = true } }

    func language(in samples: [Float], settings: DecodingSettings) async throws -> String {
        held.withLock { $0.isHolding = true }
        while !held.withLock({ $0.isReleased }) { try? await Task.sleep(for: .milliseconds(5)) }
        return settings.language == DecodingSettings.automaticLanguage ? "de" : settings.language
    }

    func transcribe(
        samples: [Float], settings: DecodingSettings, from start: TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void,
        onSegment: @escaping @Sendable (Segment) -> Void
    ) async throws -> [Segment] {
        asked.withLock { $0.append(settings.language) }
        let segment = Segment(start: start, end: start + 0.25, text: "Guten Tag.")
        onSegment(segment)
        return [segment]
    }

    func drain() async {}
}

/// A model and a recording's transcript on Automatic, stopped with `segments`.
@MainActor
private func automatic(
    with segments: [Segment], on engine: DetectingEngine, in folder: URL
) throws -> (model: AppModel, id: Entry.ID) {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let recording = folder.appending(path: "lecture.wav")
    try FileManager.default.copyItem(at: clip, to: recording)
    var entry = Entry(
        recording: recording, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false, language: DecodingSettings.automaticLanguage)
    entry.publish(segments, partial: true)
    entry.state = .stopped
    let history = folder.appending(path: "History")
    try HistoryStore.write(entry, in: history)
    let engines = Engines(
        installed: { [ModelCatalog.recommended.id] }, open: { _, _ in engine },
        speech: { samples, _ in [0...Double(samples.count) / Double(AudioDecoder.sampleRate)] })
    return (AppModel(history: history, engines: engines), entry.id)
}

@MainActor
private func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

/// A part of a recording on Automatic is read in the language decided for the
/// whole, and the transcript keeps saying Automatic.
@Test @MainActor func aResumeOnAutomaticKeepsTheDecisionForTheWhole() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = DetectingEngine()
    let first = Segment(start: 0, end: 0.25, text: "Guten Morgen.")
    let (model, id) = try automatic(with: [first], on: engine, in: folder)

    model.resumeStopped(id)
    try await until { !model.hasWork && !model.stage.isBusy }

    #expect(engine.languages == ["de"])
    #expect(model.entry(id)?.language == DecodingSettings.automaticLanguage)
    await model.shutDown()
}

@Test @MainActor func aRepairOnAutomaticKeepsTheDecisionForTheWhole() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = DetectingEngine()
    let loop = (0..<12).map {
        Segment(start: Double($0) * 0.25, end: Double($0 + 1) * 0.25, text: "Danke.")
    }
    let (model, id) = try automatic(with: loop, on: engine, in: folder)

    model.repairRepeats(id)
    try await until { !model.stage.isBusy }

    #expect(engine.languages == ["de"])
    await model.shutDown()
}

/// A stop while the engine decides ends the job, whatever the decision then says.
@Test @MainActor func aStopWhileDecidingEndsTheResume() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = DetectingEngine()
    engine.holdInTheDecision()
    let first = Segment(start: 0, end: 0.25, text: "Guten Morgen.")
    let (model, id) = try automatic(with: [first], on: engine, in: folder)

    model.resumeStopped(id)
    try await until { engine.isHolding }
    model.cancel()
    engine.release()
    try await until { !model.hasWork && !model.stage.isBusy }

    #expect(engine.languages.isEmpty)
    #expect(model.entry(id)?.state == .stopped)
    #expect(model.entry(id)?.resumedAt == nil)
    await model.shutDown()
}

/// A run from the start leaves the decision to the run itself.
@Test @MainActor func aRunFromTheStartOnAutomaticAsksTheModelToDetect() async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = DetectingEngine()
    let (model, id) = try automatic(with: [], on: engine, in: folder)

    model.retry(id)
    try await until { !model.hasWork && !model.stage.isBusy }

    #expect(engine.languages == [DecodingSettings.automaticLanguage])
    await model.shutDown()
}

/// A language shows only beside a model told it, before a start and after.
@Test(arguments: [
    (ModelCatalog.turbo, true), (ModelCatalog.qwen, true),
    (ModelCatalog.moss, false), (ModelCatalog.voxtral, false),
])
@MainActor
func theSummaryNamesALanguageOnlyForAModelToldIt(chosen: Model, names: Bool) {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(
        history: root.appending(path: "History"), glossaries: root.appending(path: "Glossaries"),
        defaults: MemoryDefaults())
    model.selected = chosen.id
    model.language = "de"
    #expect(StartBar.summary(of: model).contains("German") == names)

    let scheduled = Entry(
        recording: URL(filePath: "/made/up.m4a"), modelFile: chosen.id, glossary: nil,
        skipsSilence: false, subtitles: false, language: "de")
    #expect(StartBar.summary(of: scheduled).contains("German") == names)
}

/// Automatic is remembered as a language is, and names none in the summary.
@Test(arguments: [ModelCatalog.turbo, ModelCatalog.qwen])
@MainActor
func automaticIsRememberedAndNamesNoLanguage(chosen: Model) {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appending(path: "History")
    let glossaries = root.appending(path: "Glossaries")
    let defaults = MemoryDefaults()
    let first = AppModel(history: history, glossaries: glossaries, defaults: defaults)
    first.language = DecodingSettings.automaticLanguage

    let next = AppModel(history: history, glossaries: glossaries, defaults: defaults)
    next.selected = chosen.id
    #expect(next.language == DecodingSettings.automaticLanguage)
    #expect(next.toldLanguage == nil)
    #expect(StartBar.summary(of: next).contains(chosen.name))
    #expect(!StartBar.summary(of: next).contains("auto"))
}

@Test func anEngineThatDetectsTheLanguageSaysSo() {
    for engine in Engine.allCases {
        #expect(engine.features.contains("Detects the language") == engine.detectsLanguage)
    }
}

/// The word stored comes back as it went, and needs no newer version to read.
@Test func automaticIsStoredAsAWord() throws {
    let entry = Entry(
        recording: URL(filePath: "/made/up.wav"), modelFile: ModelCatalog.turbo.id, glossary: nil,
        skipsSilence: false, subtitles: false, language: DecodingSettings.automaticLanguage)
    let stored = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(entry))
    #expect(stored.language == "auto")
    #expect(stored.requires == nil)
}

/// Filler words carry over from the last export only where the language is known.
@Test(arguments: [
    (ModelCatalog.turbo, "fr", true),
    (ModelCatalog.turbo, DecodingSettings.automaticLanguage, false),
    (ModelCatalog.qwen, DecodingSettings.automaticLanguage, false),
    (ModelCatalog.voxtral, "fr", false),
])
@MainActor
func fillerWordsCarryOnlyWhereTheLanguageIsKnown(chosen: Model, language: String, carries: Bool) {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = MemoryDefaults()
    defaults.set(true, forKey: AppModel.removesHesitationsKey)
    let model = AppModel(
        history: root.appending(path: "History"), glossaries: root.appending(path: "Glossaries"),
        defaults: defaults)
    let entry = model.adoptingLastExport(
        Entry(
            recording: URL(filePath: "/made/up.wav"), modelFile: chosen.id, glossary: nil,
            skipsSilence: false, subtitles: false, language: language))
    #expect((entry.removesHesitations == true) == carries)
}

/// Told no language, as on Automatic, Qwen still writes what is said.
@Test(.enabled(if: ModelStore.isInstalled(ModelCatalog.qwen)))
func qwenWritesWhatIsSaidOnAutomatic() async throws {
    let engine = try await AudioCppEngine.load(
        model: ModelStore.location(of: ModelCatalog.qwen), expecting: ModelCatalog.qwen)
    var settings = DecodingSettings()
    settings.language = DecodingSettings.automaticLanguage
    let french = clip.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "clip-fr.wav")

    let segments = try await engine.transcribe(
        samples: AudioDecoder.samples(of: french), settings: settings)

    #expect(segments.map(\.text).joined().contains("Freud"))
}
