// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import audiocpp
import os

/// Runs a model through audio.cpp (Qwen3-ASR, MOSS-Transcribe-Diarize or
/// Voxtral Realtime), one family per loaded model.
///
/// The recording is cut here into the windows of the family's profile, one
/// call each, because the C API has no callback. This way progress, a stop
/// and the text of each window reach the app as they happen. A stop waits
/// for the window under way, except where the text or the audio is streamed.
///
/// Every native call runs on one serial queue, which is what makes the class
/// safe to share, as with `WhisperEngine`.
nonisolated final class AudioCppEngine: TranscriptionEngine, @unchecked Sendable {
    private let profile: AudioCppProfile
    /// Whether Qwen3 Forced Aligner times each word, so that segments follow
    /// sentences rather than windows.
    let aligns: Bool
    private let session: OpaquePointer
    private let queue = DispatchQueue(
        label: "io.github.miravassor.Polycop.audiocpp", qos: .userInitiated)

    /// Loading reads gigabytes of weights and prepares Metal, off the calling
    /// actor. The contents are proven before the native parser sees them.
    /// `profile` replaces the family's own only for measurements.
    static func load(
        model: URL, expecting catalogued: Model, aligner: (file: URL, model: Model)? = nil,
        profile: AudioCppProfile? = nil
    ) async throws -> AudioCppEngine {
        try refuse(model, catalogued)
        guard let profile = profile ?? catalogued.engine.audioCpp else {
            throw ModelStore.ImportError.unrecognized
        }
        try await ModelStore.verify(catalogued, at: model)
        if let aligner { try await ModelStore.verify(aligner.model, at: aligner.file) }
        try Task.checkCancellation()
        return try await loadingQueue.run {
            try AudioCppEngine(model: model, profile: profile, aligner: aligner?.file)
        }
    }

    private static let loadingQueue = DispatchQueue(
        label: "io.github.miravassor.Polycop.audiocpp.load", qos: .userInitiated)

    /// The session keeps the model and the registry alive on its own, so both
    /// are released as soon as it exists (docs/c_api.md, Lifetime).
    private init(model: URL, profile: AudioCppProfile, aligner: URL?) throws {
        guard audiocpp_abi_version() >> 16 == AUDIOCPP_ABI_VERSION_MAJOR else {
            throw TranscriptionError.modelUnreadable(model)
        }
        var registry: OpaquePointer?
        var loaded: OpaquePointer?
        var session: OpaquePointer?
        guard let options = audiocpp_options_create() else {
            throw TranscriptionError.failed(Int32(AUDIOCPP_ERR_OUT_OF_MEMORY.rawValue))
        }
        defer {
            audiocpp_options_free(options)
            audiocpp_model_free(loaded)
            audiocpp_registry_free(registry)
        }
        if let aligner {
            try Self.check(
                audiocpp_options_set(
                    options, "qwen3_asr.forced_aligner_model_path",
                    aligner.path(percentEncoded: false)))
        }
        let threads = Int32(DecodingSettings.performanceCores)
        let mode = profile.feed == .whole ? "offline" : "streaming"
        let status = profile.family.withCString { family in
            "metal".withCString { backend in
                var config = audiocpp_model_config(
                    family_hint: family, config_id: nil, weight_id: nil,
                    model_spec_override: nil)
                var device = audiocpp_backend_config(backend: backend, device: 0, threads: threads)
                var status = audiocpp_registry_create(nil, &registry)
                if status == AUDIOCPP_OK {
                    status = audiocpp_model_load(
                        registry, model.path(percentEncoded: false), &config, nil, &loaded)
                }
                if status == AUDIOCPP_OK {
                    status = audiocpp_session_create(
                        loaded, "asr", mode, &device, options, &session)
                }
                return status
            }
        }
        guard status == AUDIOCPP_OK, let session else {
            audiocpp_session_free(session)
            Log.transcription.error(
                "audio.cpp could not open the model: \(String(cString: audiocpp_last_error()), privacy: .private)"
            )
            throw TranscriptionError.modelUnreadable(model)
        }
        self.profile = profile
        self.aligns = aligner != nil
        self.session = session
    }

    /// Every call on the queue holds the engine, so it cannot be freed while
    /// a window runs.
    deinit {
        audiocpp_session_free(session)
    }

    func drain() async {
        await queue.run {}
    }

    /// Qwen reads no less than half a second; the official toolkit pads a
    /// shorter piece with silence, and so does this.
    private static let shortestInput = AudioDecoder.sampleRate / 2

    // MARK: Transcription

    /// Transcribes window after window. Only the language and the glossary of
    /// the settings apply, where the family reads them. The rest belong to
    /// whisper.cpp.
    func transcribe(
        samples: [Float],
        settings: DecodingSettings,
        from start: TimeInterval = 0,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        onSegment: @escaping @Sendable (Segment) -> Void = { _ in }
    ) async throws -> [Segment] {
        let first = try Self.firstSample(at: start, count: samples.count)
        let windows = Self.windows(
            in: samples, from: first, lasting: profile.window, atSilence: profile.cutsAtSilence)
        let language = Self.qwenLanguages[settings.language] ?? ""
        let hotwords = profile.readsHotwords ? settings.prompt.map(Glossary.terms(in:)) ?? [] : []
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await queue.run {
                func stopIfAsked() throws {
                    if cancelled.withLock({ $0 }) { throw CancellationError() }
                }
                var segments: [Segment] = []
                for (done, window) in windows.enumerated() {
                    try stopIfAsked()
                    let found: [Segment]
                    do {
                        found = try self.transcribe(
                            samples, window, language: language, hotwords: hotwords,
                            until: stopIfAsked,
                            progress: {
                                onProgress((Double(done) + $0) / Double(windows.count))
                            })
                    } catch let stopped as StoppedWindow {
                        // Kept like the windows before, so a pause resumes after them.
                        stopped.segments.forEach(onSegment)
                        throw CancellationError()
                    }
                    segments += found
                    found.forEach(onSegment)
                    onProgress(Double(done + 1) / Double(windows.count))
                }
                // Catches a stop that arrived during the last window.
                try stopIfAsked()
                return segments
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// One window, on the queue. The window is already cut, so Qwen is told
    /// not to cut it again. A MOSS window stopped by its token limit is read
    /// again once from the end of its last finished passage, when that
    /// leaves something to read.
    private func transcribe(
        _ samples: [Float], _ window: Range<Int>, language: String, hotwords: [String],
        retriesCut: Bool = true,
        until stopIfAsked: () throws -> Void, progress: (Double) -> Void
    ) throws -> [Segment] {
        guard let request = audiocpp_request_create() else {
            throw TranscriptionError.failed(Int32(AUDIOCPP_ERR_OUT_OF_MEMORY.rawValue))
        }
        defer { audiocpp_request_free(request) }
        defer {
            if profile.feed != .whole { _ = audiocpp_stream_reset(session) }
        }
        var audio = Array(samples[window])
        if audio.count < Self.shortestInput {
            audio += [Float](repeating: 0, count: Self.shortestInput - audio.count)
        }
        try configure(request, audio: audio, language: language, hotwords: hotwords)

        let rate = Double(AudioDecoder.sampleRate)
        var result: OpaquePointer?
        defer { audiocpp_result_free(result) }
        switch profile.feed {
        case .whole:
            try Self.check(audiocpp_session_run(session, request, &result))
        case .text:
            return try transcribeMoss(
                window, request, until: stopIfAsked, progress: progress
            ) { rest, done in
                guard retriesCut else { return nil }
                return try transcribe(
                    samples, rest, language: language, hotwords: hotwords, retriesCut: false,
                    until: stopIfAsked, progress: { progress(done + $0 * (1 - done)) })
            }
        case .audio:
            return try Self.streamVoxtral(
                to: session, audio, request, from: Double(window.lowerBound) / rate,
                until: stopIfAsked, progress: progress)
        }
        return try Self.qwenSegments(of: result, in: window)
    }

    /// A MOSS window. When its token limit stopped it, `again` reads the rest
    /// from its last finished passage, given the part of the window already
    /// done, or answers nil.
    private func transcribeMoss(
        _ window: Range<Int>, _ request: OpaquePointer,
        until stopIfAsked: () throws -> Void, progress: (Double) -> Void,
        again: (Range<Int>, Double) throws -> [Segment]?
    ) throws -> [Segment] {
        let rate = Double(AudioDecoder.sampleRate)
        let length = Double(window.count) / rate
        func segments(of text: String, isComplete: Bool) -> [Segment] {
            Self.mossSegments(
                in: text, from: Double(window.lowerBound) / rate, lasting: length,
                isComplete: isComplete)
        }
        let read: (text: String, isComplete: Bool)
        do {
            read = try Self.readMoss(
                from: session, request, lasting: length, until: stopIfAsked,
                progress: progress)
        } catch let stopped as StoppedReading {
            throw StoppedWindow(segments: segments(of: stopped.text, isComplete: false))
        }
        let found = segments(of: read.text, isComplete: read.isComplete)
        guard !read.isComplete, let rest = Self.rest(of: window, after: found.last?.end) else {
            return found
        }
        let done = Double(rest.lowerBound - window.lowerBound) / Double(window.count)
        do {
            return try found + (again(rest, done) ?? [])
        } catch let stopped as StoppedWindow {
            throw StoppedWindow(segments: found + stopped.segments)
        }
    }

    /// A stop inside a window, with the passages that window had finished.
    struct StoppedWindow: Error {
        let segments: [Segment]
    }

    /// What is left of a window after its last finished passage, when that
    /// passage ended a second or more into it and before its last second.
    static func rest(of window: Range<Int>, after end: TimeInterval?) -> Range<Int>? {
        guard let end else { return nil }
        let rate = AudioDecoder.sampleRate
        let start = Int(end * Double(rate))
        guard start >= window.lowerBound + rate, start <= window.upperBound - rate else {
            return nil
        }
        return start..<window.upperBound
    }

    /// Sets the audio, language, glossary hotwords and alignment option on a
    /// request, before it is run or streamed.
    private func configure(
        _ request: OpaquePointer, audio: [Float], language: String, hotwords: [String]
    ) throws {
        if profile.feed == .audio {
            // Only the format here; the samples are pushed afterwards, as for
            // a live input to audiocpp_cli.
            try Self.check(
                audiocpp_request_set_audio(request, nil, 0, Int32(AudioDecoder.sampleRate), 1))
        } else {
            // audio.cpp copies the samples into the request (audiocpp.h).
            try audio.withUnsafeBufferPointer {
                try Self.check(
                    audiocpp_request_set_audio(
                        request, $0.baseAddress, $0.count, Int32(AudioDecoder.sampleRate), 1))
            }
        }
        if profile.setsLanguage {
            // No earlier text is carried between windows.
            try Self.check(audiocpp_request_set_text(request, "", language))
        }
        for (key, value) in profile.options {
            try Self.check(audiocpp_request_set_option(request, key, value))
        }
        if !hotwords.isEmpty {
            let instruction = Self.mossInstruction + "热词提示：" + hotwords.joined(separator: ", ")
            try Self.check(audiocpp_request_set_option(request, "instruct", instruction))
        }
        if aligns {
            try Self.check(audiocpp_request_set_option(request, "return_timestamps", "true"))
        }
    }

    /// Bytes rather than text: a streamed piece can end inside a character.
    static func bytes(of result: OpaquePointer?) throws -> [UInt8] {
        var text: UnsafePointer<CChar>?
        let status = audiocpp_result_text(result, &text, nil)
        if status == AUDIOCPP_ERR_NOT_AVAILABLE { return [] }
        try check(status)
        return text.map { Array(UnsafeRawBufferPointer(start: $0, count: strlen($0))) } ?? []
    }

    static func text(of result: OpaquePointer?) throws -> String {
        String(decoding: try bytes(of: result), as: UTF8.self)
    }

    /// The detail of a failure can quote the recording, so it goes to the log
    /// as private and the window shows the code.
    static func check(_ status: audiocpp_status) throws {
        guard status != AUDIOCPP_OK else { return }
        Log.transcription.error(
            "audio.cpp failed: \(String(cString: audiocpp_last_error()), privacy: .private)")
        throw TranscriptionError.failed(Int32(status.rawValue))
    }
}
