// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Testing
import os

@testable import Polycop

private let repository = URL(filePath: #filePath)
    .deletingLastPathComponent()  // PolycopTests
    .deletingLastPathComponent()  // App
    .deletingLastPathComponent()  // repository

private let fixture = repository.appending(path: "App/PolycopTests/Fixtures/clip-fr.wav")
private let commandLineTool = repository.appending(path: "build/audiocpp-build/bin/audiocpp_cli")

/// The model is read from the app's own store, as for Whisper, and the tests
/// that need it are skipped where it is not installed.
private let model = ModelStore.location(of: ModelCatalog.qwen)
private let modelInstalled = ModelStore.isInstalled(ModelCatalog.qwen)
private let toolBuilt = FileManager.default.isExecutableFile(atPath: commandLineTool.path)

private let second = AudioDecoder.sampleRate

/// Forty seconds of the clip with half a second between repeats, giving two
/// windows, both with speech in them.
private func twoWindows() async throws -> [Float] {
    let clip = try await AudioDecoder.samples(of: fixture)
    let gap = [Float](repeating: 0, count: second / 2)
    var samples: [Float] = []
    while samples.count < 40 * second { samples += clip + gap }
    return samples
}

/// Writes 16-bit samples, the format the command line tool reads, and returns
/// them as read back, so both sides are given exactly the same audio.
private func write(_ samples: [Float], to url: URL) throws -> [Float] {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(second),
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ]
    do {
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        let channel = try #require(buffer.floatChannelData)[0]
        try samples.withUnsafeBufferPointer {
            channel.update(from: try #require($0.baseAddress), count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(
        AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData)[0]
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

/// Qwen's windows are cut exactly, as audio.cpp cuts them.
@Test func qwensWindowsAreCutExactly() {
    let samples = [Float](repeating: 0.1, count: 65 * second)
    #expect(
        AudioCppEngine.windows(in: samples, from: 0, lasting: 30, atSilence: false) == [
            0..<30 * second, 30 * second..<60 * second, 60 * second..<65 * second,
        ])
}

/// A tone with a silence near each nominal cut. The windows end in the
/// silences, cover the recording once, and a resume starts where asked.
@Test func theWindowsEndInTheNearestSilence() {
    var samples = (0..<(65 * second)).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    for quiet in [28 * second, 58 * second] {
        for index in quiet..<(quiet + second / 5) { samples[index] = 0 }
    }

    let windows = AudioCppEngine.windows(in: samples, from: 0, lasting: 30, atSilence: true)

    #expect(windows.count == 3)
    #expect(windows.first?.lowerBound == 0 && windows.last?.upperBound == samples.count)
    #expect(zip(windows, windows.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    #expect((28 * second..<(28 * second + second / 5)).contains(windows[0].upperBound))
    #expect((58 * second..<(58 * second + second / 5)).contains(windows[1].upperBound))
    #expect(
        AudioCppEngine.windows(in: samples, from: 40 * second, lasting: 30, atSilence: true).first?
            .lowerBound
            == 40 * second)
    #expect(
        AudioCppEngine.windows(in: samples, from: samples.count, lasting: 30, atSilence: true)
            .isEmpty)
}

/// Each family is loaded under its own name and cut at its own window length;
/// Whisper does not go through audio.cpp.
@Test func everyAudioCppFamilyHasAProfile() {
    #expect(Engine.qwen.audioCpp?.window == 30)
    #expect(Engine.moss.audioCpp?.window == 300)
    #expect(Engine.voxtral.audioCpp?.window == 300)
    #expect(Engine.whisper.audioCpp == nil)
    #expect(Engine.moss.timesSentences && !Engine.voxtral.timesSentences)
    #expect(
        ModelCatalog.all.filter(\.readsGlossary).allSatisfy {
            $0.engine == .whisper || $0.engine == .moss
        })
}

@Test func reportsAQwenModelItCannotRead() async {
    await #expect(throws: TranscriptionError.self) {
        _ = try await AudioCppEngine.load(
            model: repository.appending(path: "no-such-model.gguf"), expecting: ModelCatalog.qwen)
    }
}

extension LoadingAModel {
    /// One segment per window, timed by the window, and French text in both.
    @Test(.enabled(if: modelInstalled))
    func qwenTranscribesEachWindowAtItsPlace() async throws {
        let engine = try await AudioCppEngine.load(model: model, expecting: ModelCatalog.qwen)
        let samples = try await twoWindows()
        let duration = Double(samples.count) / Double(second)

        let segments = try await engine.transcribe(samples: samples, settings: DecodingSettings())

        #expect(segments.map(\.start) == [0, 30])
        #expect(segments.last?.end == duration)
        #expect(segments.allSatisfy { !$0.text.isEmpty })
    }

    /// The app cuts the windows itself, so it must return what audio.cpp's own
    /// tool returns when it cuts them, for the same audio.
    @Test(.enabled(if: modelInstalled && toolBuilt))
    func qwenMatchesTheCommandLineTool() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appending(path: "two-windows.wav")
        let text = folder.appending(path: "two-windows.txt")
        let samples = try write(try await twoWindows(), to: audio)

        let engine = try await AudioCppEngine.load(model: model, expecting: ModelCatalog.qwen)
        let segments = try await engine.transcribe(samples: samples, settings: DecodingSettings())

        let process = Process()
        process.executableURL = commandLineTool
        process.arguments = [
            "--task", "asr", "--family", "qwen3_asr",
            "--model", model.path(percentEncoded: false),
            "--backend", "metal", "--mode", "offline",
            "--audio", audio.path(percentEncoded: false),
            "--text-out", text.path(percentEncoded: false),
            "--language", "French", "--text", "",
            "--audio-chunk-mode", "auto", "--audio-chunk-seconds", "30",
            "--max-tokens", "1024",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let printed = try String(contentsOf: text, encoding: .utf8)
        #expect(
            segments.map(\.text).joined(separator: " ")
                == printed.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A stop reaches the engine between two windows, and during the last one.
    @Test(.enabled(if: modelInstalled))
    func qwenStopsBetweenWindows() async throws {
        let engine = try await AudioCppEngine.load(model: model, expecting: ModelCatalog.qwen)
        let samples = try await twoWindows()
        let first = OSAllocatedUnfairLock(initialState: false)

        let work = Task {
            try await engine.transcribe(
                samples: samples, settings: DecodingSettings(),
                onSegment: { _ in first.withLock { $0 = true } })
        }
        for _ in 0..<600 where !first.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        work.cancel()

        await #expect(throws: CancellationError.self) { _ = try await work.value }
        await engine.drain()
    }
}

@Test func bothEnginesBoundTheStartBeforeConvertingItToSamples() throws {
    #expect(try AudioCppEngine.firstSample(at: -1, count: 100) == 0)
    #expect(try AudioCppEngine.firstSample(at: .greatestFiniteMagnitude, count: 100) == 100)
    #expect(throws: TranscriptionError.self) {
        _ = try WhisperEngine.firstSample(at: .nan, count: 100)
    }
    #expect(throws: TranscriptionError.self) {
        _ = try AudioCppEngine.firstSample(at: .infinity, count: 100)
    }
}

extension LoadingAModel {
    @Test(.enabled(if: modelInstalled))
    func qwenReleasesItsSessionAfterDraining() async throws {
        var engine: AudioCppEngine? = try await AudioCppEngine.load(
            model: model, expecting: ModelCatalog.qwen)
        weak let reference = engine
        _ = try await engine?.transcribe(samples: [], settings: DecodingSettings())
        await engine?.drain()
        engine = nil
        #expect(reference == nil)
    }
}

/// Sentences take the times of the aligner's words that spell them, however
/// the aligner split and stripped those words.
@Test func sentencesAreTimedByTheirWords() {
    let words: [TimedWords.Word] = [
        .init(text: "Bonjour", start: 0.2, end: 0.6), .init(text: "à", start: 0.6, end: 0.7),
        .init(text: "tous", start: 0.7, end: 1.0), .init(text: "L", start: 1.8, end: 1.9),
        .init(text: "encodage", start: 1.9, end: 2.5), .init(text: "d", start: 2.5, end: 2.6),
        .init(text: "abord", start: 2.6, end: 3.1),
    ]

    let sentences = TimedWords.sentences(
        of: "Bonjour à tous. L'encodage, d'abord ?", timedBy: words)

    #expect(
        sentences?.map { $0.replacing(text: $0.text) } == [
            Segment(start: 0.2, end: 1.0, text: "Bonjour à tous."),
            Segment(start: 1.8, end: 3.1, text: "L'encodage, d'abord ?"),
        ])
    // Each sentence keeps the words that time it, to play from one of them.
    #expect(sentences?.map { $0.words?.count } == [3, 4])
}

/// Words that do not spell the text give no times rather than wrong ones.
@Test func mismatchedWordsGiveNoSentences() {
    let words: [TimedWords.Word] = [.init(text: "Bonsoir", start: 0, end: 1)]
    #expect(TimedWords.sentences(of: "Bonjour.", timedBy: words) == nil)
    #expect(TimedWords.sentences(of: "Bonjour.", timedBy: []) == nil)
}

/// MOSS writes its times in brackets; the last one is how far it has reached.
@Test func mossProgressIsReadFromItsLastTime() {
    #expect(AudioCppEngine.lastTime(in: "[0.08][S01] Bonjour à tous.[3.24]") == 3.24)
    #expect(AudioCppEngine.lastTime(in: "[12.5][S02]") == nil)
    #expect(AudioCppEngine.lastTime(in: "pas encore") == nil)
}

@Test func mossPassagesBecomeSegmentsOnTheRecording() {
    let text = "[0.00][S01] Bonjour à tous.[2.50][2.50][S02] Oui ?[3.10]"
    #expect(
        AudioCppEngine.mossSegments(in: text, from: 60, lasting: 300, isComplete: true) == [
            Segment(start: 60, end: 62.5, text: "Bonjour à tous.", speaker: "S01"),
            Segment(start: 62.5, end: 63.1, text: "Oui ?", speaker: "S02"),
        ])
}

@Test func mossPassagesAudioCppSkipsAreSkipped() {
    // No text, an end before the start, then times written "12." and past the window.
    let text = "[1.0][S01]  [2.0][7.0][S01] Non.[6.5][12.][S01] Fin.[400]"
    #expect(
        AudioCppEngine.mossSegments(in: text, from: 0, lasting: 300, isComplete: true) == [
            Segment(start: 12, end: 300, text: "Fin.", speaker: "S01")
        ])
}

@Test func anUnfinishedMossPassageIsLeftOut() {
    let text = "[0.0][S01] Un.[1.0][1.0][S01] deux deux deux deux"
    for isComplete in [true, false] {
        #expect(
            AudioCppEngine.mossSegments(in: text, from: 0, lasting: 300, isComplete: isComplete)
                == [Segment(start: 0, end: 1, text: "Un.", speaker: "S01")])
    }
}

@Test func mossTextWithoutPassagesIsOneSegmentWithoutMarkup() {
    let text = "[0.0][S01] Bonjour\nà tous"
    #expect(
        AudioCppEngine.mossSegments(in: text, from: 30, lasting: 5, isComplete: true) == [
            Segment(start: 30, end: 35, text: "Bonjour à tous")
        ])
    // A window stopped by its token limit keeps nothing unfinished.
    #expect(
        AudioCppEngine.mossSegments(in: text, from: 30, lasting: 5, isComplete: false).isEmpty)
}

@Test func leadingPunctuationFallsBackToTheUnchangedTranscript() {
    #expect(
        TimedWords.sentences(
            of: "... Bonjour.",
            timedBy: [
                .init(text: "Bonjour", start: 0, end: 1)
            ]) == nil)
}

@Test func invalidWindowLengthsCannotLoopOrTrap() {
    let samples: [Float] = [0, 0, 0]
    for duration in [0.0, -1, .infinity, .nan] {
        #expect(
            AudioCppEngine.windows(in: samples, from: 0, lasting: duration, atSilence: false)
                .isEmpty)
    }
    #expect(
        AudioCppEngine.windows(in: samples, from: 0, lasting: 0.000001, atSilence: false) == [
            0..<1, 1..<2, 2..<3,
        ])
}

@Test func voxtralSegmentsFollowTheTextReadAtEachSpan() {
    let transcript = Array(" Bonjour à tous. Nous commençons.".utf8)
    let read = " Bonjour à tous.".utf8.count
    let segments = AudioCppEngine.streamedSegments(
        of: transcript, streamed: Array(transcript[..<read]), marks: [(480_000, read)],
        lasting: 800_000, from: 60)
    #expect(
        segments == [
            Segment(start: 60, end: 90, text: "Bonjour à tous."),
            Segment(start: 90, end: 110, text: "Nous commençons."),
        ])
}

@Test func aVoxtralSpanEndingInsideAWordOrACharacterEndsAfterIt() {
    let transcript = Array(" Il a commencé tôt".utf8)
    // Inside "commencé", then between the two bytes of its "é".
    for read in [8, " Il a commenc".utf8.count + 1] {
        let segments = AudioCppEngine.streamedSegments(
            of: transcript, streamed: Array(transcript[..<read]), marks: [(16_000, read)],
            lasting: 32_000, from: 0)
        #expect(segments.map(\.text) == ["Il a commencé", "tôt"])
    }
}

@Test func voxtralTextThatDisagreesWithTheStreamIsOneSegment() {
    let segments = AudioCppEngine.streamedSegments(
        of: Array(" Bonjour à tous.".utf8), streamed: Array(" Bonsoir".utf8),
        marks: [(16_000, 8)], lasting: 32_000, from: 5)
    #expect(segments == [Segment(start: 5, end: 7, text: "Bonjour à tous.")])
}

@Test func voxtralSpansWithoutTextOrPastTheWindowAreSkipped() {
    // Nothing read by the first mark, a count past the text, a mark at the end.
    let segments = AudioCppEngine.streamedSegments(
        of: Array(" Bonjour.".utf8), streamed: [],
        marks: [(16_000, 0), (32_000, 99), (48_000, 9)], lasting: 48_000, from: 0)
    #expect(segments == [Segment(start: 1, end: 2, text: "Bonjour.")])
    #expect(
        AudioCppEngine.streamedSegments(
            of: [], streamed: [], marks: [], lasting: 16_000, from: 0
        ).isEmpty)
}

extension LoadingAModel {
    @Test(
        .enabled(
            if: ModelStore.isInstalled(ModelCatalog.moss)
                && ModelStore.isInstalled(ModelCatalog.voxtral)),
        arguments: [ModelCatalog.moss, ModelCatalog.voxtral])
    func additionalFamiliesReleaseAndReuseTheirStreams(model: Model) async throws {
        let engine = try await AudioCppEngine.load(
            model: ModelStore.location(of: model), expecting: model)
        let samples = try await AudioDecoder.samples(of: fixture)
        let first = try await engine.transcribe(samples: samples, settings: DecodingSettings())
        let second = try await engine.transcribe(samples: samples, settings: DecodingSettings())
        #expect(!first.isEmpty)
        #expect(first == second)
        #expect(
            first.allSatisfy {
                $0.start >= 0 && $0.end >= $0.start && $0.end <= Double(samples.count) / 16000
            })
        await engine.drain()
    }
}

extension LoadingAModel {
    /// Before the fix, the first window stopped by its limit failed the job.
    @Test(.enabled(if: ModelStore.isInstalled(ModelCatalog.moss)))
    func aMossWindowStoppedByItsTokenLimitLetsTheNextOnesRun() async throws {
        let limited = AudioCppProfile(
            family: "moss_transcribe_diarize", window: 3, cutsAtSilence: false, feed: .text,
            setsLanguage: false, readsHotwords: false, options: ["max_tokens": "12"])
        let engine = try await AudioCppEngine.load(
            model: ModelStore.location(of: ModelCatalog.moss), expecting: ModelCatalog.moss,
            profile: limited)
        let samples = try await AudioDecoder.samples(of: fixture)
        let progress = OSAllocatedUnfairLock(initialState: 0.0)
        let segments = try await engine.transcribe(
            samples: samples, settings: DecodingSettings(),
            onProgress: { value in progress.withLock { $0 = value } })
        #expect(progress.withLock { $0 } == 1)
        #expect(segments.allSatisfy { $0.end <= Double(samples.count) / 16000 })
        await engine.drain()
    }
}
