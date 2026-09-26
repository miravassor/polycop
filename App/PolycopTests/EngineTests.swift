// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Testing

@testable import Polycop

// This target runs nonisolated by default, unlike the app, because the
// engine under test is nonisolated; a test needing the main actor says so.

/// The repository, found from this file, so the tests reach the fixture and a
/// whisper-cli built from the pinned whisper.cpp beside it.
private let repository = URL(filePath: #filePath)
    .deletingLastPathComponent()  // PolycopTests
    .deletingLastPathComponent()  // App
    .deletingLastPathComponent()  // repository

private let fixture = repository.appending(path: "App/PolycopTests/Fixtures/clip-fr.wav")
private let commandLineTool = repository.appending(
    path: "build/whisper-source/build/bin/whisper-cli")

/// Models are downloaded, never committed, so the tests that need one read the
/// app's own store and are skipped where nothing is installed.
private let model = ModelStore.location(of: ModelCatalog.turbo)
private let modelInstalled = ModelStore.isInstalled(ModelCatalog.turbo)
private let toolBuilt = FileManager.default.isExecutableFile(atPath: commandLineTool.path)

private let glossary =
    "Ce cours de psychanalyse porte sur Freud, principe de plaisir, première topique."

private func samples(of audio: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: audio)
    let buffer = try #require(
        AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData)[0]
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

/// Returns the words of `text`, ignoring the spacing differences between the
/// engine and the command line tool.
private func words(_ text: String) -> [String] {
    text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
}

@Test func reportsAModelItCannotRead() async {
    await #expect(throws: TranscriptionError.self) {
        _ = try await WhisperEngine.load(model: repository.appending(path: "no-such-model.bin"))
    }
}

/// Tests that load a model run one at a time, because each holds close to
/// 3 GB on the GPU, more than parallel runs can share.
@Suite(.serialized) struct LoadingAModel {}

extension LoadingAModel {
    @Test(.enabled(if: modelInstalled))
    func transcribesFrenchWithTheGlossary() async throws {
        let engine = try await WhisperEngine.load(model: model)
        var settings = DecodingSettings()
        settings.prompt = glossary

        let segments = try await engine.transcribe(
            samples: samples(of: fixture), settings: settings)
        let transcript = segments.map(\.text).joined()

        #expect(transcript.contains("Freud"))
        #expect(segments.first?.start == 0)
        #expect((segments.last?.end ?? 0) > 3)
        let words = segments.flatMap { $0.words ?? [] }
        #expect(words.map(\.text).joined(separator: " ").contains("Freud"))
        #expect(words.allSatisfy { ($0.confidence ?? -1) >= 0 && ($0.confidence ?? 2) <= 1 })
        #expect(words.allSatisfy { $0.start <= $0.end })
    }

    /// The engine must return what whisper-cli itself returns, called with the
    /// same settings.
    @Test(.enabled(if: modelInstalled && toolBuilt))
    func matchesTheCommandLineTool() async throws {
        var settings = DecodingSettings()
        settings.prompt = glossary

        let engine = try await WhisperEngine.load(model: model)
        let segments = try await engine.transcribe(
            samples: samples(of: fixture), settings: settings)

        let process = Process()
        process.executableURL = commandLineTool
        process.arguments = [
            "-m", model.path(percentEncoded: false),
            "-f", fixture.path(percentEncoded: false),
            "-l", settings.language,
            "-t", String(settings.threads),
            "-bs", String(settings.beamSize),
            "-bo", String(settings.bestOf),
            "--prompt", glossary,
            "--carry-initial-prompt",
            "-nt", "-np",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(
            words(segments.map(\.text).joined()) == words(String(decoding: printed, as: UTF8.self)))
    }

    /// A paused transcription continues from a point of the recording. The
    /// audio before it is left out, and the times land back on the recording.
    @Test(.enabled(if: modelInstalled))
    func continuesFromAPointOfTheRecording() async throws {
        let engine = try await WhisperEngine.load(model: model)
        let audio = try samples(of: fixture)
        let length = Double(audio.count) / 16_000

        let resumed = try await engine.transcribe(
            samples: audio, settings: DecodingSettings(), from: 3)

        #expect(!resumed.isEmpty)
        #expect(resumed.allSatisfy { $0.start >= 3 })
        #expect((resumed.last?.end ?? 0) <= length + 0.5)
    }

    /// The glossary is counted by the model's own tokenizer, so the warning about the
    /// 223 tokens it reads rests on the real figure.
    @Test(.enabled(if: modelInstalled))
    func countsTokensWithTheModelsTokenizer() async throws {
        let engine = try await WhisperEngine.load(model: model)
        let short = await engine.tokenCount(of: "Ce cours porte sur Descartes.")
        let long = await engine.tokenCount(
            of: "Ce cours porte sur Descartes, Pascal, Montaigne, Voltaire.")

        #expect(short > 0)
        #expect(long > short)
    }

    /// A pause right at the end resumes with nothing left to decode. Otherwise
    /// whisper.cpp would transcribe its previous audio again, returning it a
    /// second time after the clip's end.
    @Test(.enabled(if: modelInstalled))
    func resumingAtTheEndTranscribesNothing() async throws {
        let engine = try await WhisperEngine.load(model: model)
        let clip = try samples(of: fixture)
        let duration = Double(clip.count) / Double(AudioDecoder.sampleRate)
        _ = try await engine.transcribe(samples: clip, settings: DecodingSettings())

        #expect(
            try await engine.transcribe(samples: clip, settings: DecodingSettings(), from: duration)
                .isEmpty)
        #expect(
            try await engine.transcribe(
                samples: clip, settings: DecodingSettings(), from: duration + 2
            )
            .isEmpty)
    }
}

/// The detector is asked directly for each recording. Read from the context
/// after a transcription, a recording without speech would get the stretches
/// of the one before it.
@Test func theDetectorReportsWhatItKeptForEachRecording() async throws {
    var settings = DecodingSettings()
    settings.voiceActivityDetection = true
    let clip = try samples(of: fixture)
    let duration = Double(clip.count) / Double(AudioDecoder.sampleRate)

    let spoken = try await WhisperEngine.speech(in: clip, settings: settings)
    let silent = try await WhisperEngine.speech(
        in: [Float](repeating: 0, count: AudioDecoder.sampleRate * 5), settings: settings)

    #expect(!spoken.isEmpty)
    #expect(spoken.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= duration + 0.1 })
    #expect(silent.isEmpty)
}
