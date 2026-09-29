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
    /// Qwen names languages in English words where the app keeps codes.
    private static let languages = ["fr": "French", "en": "English"]

    /// MOSS's own instruction, as audio.cpp and the official repository write
    /// it; hotwords follow it in the official form (`examples/prompts.md`).
    private static let mossInstruction =
        "请将音频转写为文本，每一段需以起始时间戳和说话人编号（[S01]、[S02]、[S03]…）开头，"
        + "正文为对应的语音内容，并在段末标注结束时间戳，以清晰标明该段语音范围。"

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
        return try await withCheckedThrowingContinuation { continuation in
            loadingQueue.async {
                do {
                    continuation.resume(
                        returning: try AudioCppEngine(
                            model: model, profile: profile, aligner: aligner?.file))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
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
        let language = Self.languages[settings.language] ?? ""
        let hotwords = profile.readsHotwords ? settings.prompt.map(Glossary.terms(in:)) ?? [] : []
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    func stopIfAsked() throws {
                        if cancelled.withLock({ $0 }) { throw CancellationError() }
                    }
                    do {
                        var segments: [Segment] = []
                        for (done, window) in windows.enumerated() {
                            try stopIfAsked()
                            let found = try self.transcribe(
                                samples, window, language: language, hotwords: hotwords,
                                until: stopIfAsked,
                                progress: {
                                    onProgress((Double(done) + $0) / Double(windows.count))
                                })
                            segments += found
                            found.forEach(onSegment)
                            onProgress(Double(done + 1) / Double(windows.count))
                        }
                        // Catches a stop that arrived during the last window.
                        try stopIfAsked()
                        continuation.resume(returning: segments)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// One window, on the queue. The window is already cut, so Qwen is told
    /// not to cut it again.
    private func transcribe(
        _ samples: [Float], _ window: Range<Int>, language: String, hotwords: [String],
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
            try readText(
                request, lasting: Double(window.count) / rate, until: stopIfAsked,
                progress: progress)
            try Self.check(audiocpp_stream_finish(session, &result))
        case .audio:
            return try pushAudio(
                audio, request, from: Double(window.lowerBound) / rate, until: stopIfAsked,
                progress: progress)
        }
        return try segments(of: result, in: window)
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

    /// Reads MOSS's text token by token. The times it writes show how far
    /// into the window it has reached, which is the progress.
    private func readText(
        _ request: OpaquePointer, lasting length: TimeInterval,
        until stopIfAsked: () throws -> Void, progress: (Double) -> Void
    ) throws {
        try Self.check(audiocpp_stream_start(session, request))
        var text = ""
        while true {
            try stopIfAsked()
            var event: OpaquePointer?
            try Self.check(audiocpp_stream_next_event(session, &event))
            guard let event else { break }
            defer { audiocpp_event_free(event) }
            text += try Self.text(of: audiocpp_event_as_result(event))
            if text.hasSuffix("]"), let reached = Self.lastTime(in: text), length > 0 {
                progress(min(1, reached / length))
            }
        }
    }

    /// The last time a MOSS transcript has written, as in "[12.34]".
    static func lastTime(in text: String) -> TimeInterval? {
        guard let close = text.lastIndex(of: "]"),
            let open = text[..<close].lastIndex(of: "[")
        else { return nil }
        return TimeInterval(text[text.index(after: open)..<close])
    }

    /// Pushes the window to Voxtral in the chunks it asks for. A push returns
    /// only the last of the steps it runs (`audiocpp_stream_push`, v0.8.1),
    /// so the text read while pushing can miss some of what the final
    /// transcript, read once the stream ends, contains. That streamed text
    /// times the transcript in 30-second segments only when it matches
    /// exactly; otherwise the window is one segment. Voxtral lags the audio
    /// by its model delay of 480 ms.
    private func pushAudio(
        _ audio: [Float], _ request: OpaquePointer, from offset: TimeInterval,
        until stopIfAsked: () throws -> Void, progress: (Double) -> Void
    ) throws -> [Segment] {
        var preferred: Int64 = 0
        try Self.check(audiocpp_stream_policy(session, nil, nil, &preferred, nil))
        let chunk = max(1, Int(preferred))
        let rate = Double(AudioDecoder.sampleRate)
        let every = Int(AudioCppProfile.streamedSegment * rate)
        try Self.check(audiocpp_stream_start(session, request))
        // The text read by the end of each span of 30 seconds, and where it ends.
        var spans: [(end: Int, text: String)] = []
        var streamed = ""
        var pushed = 0
        while pushed < audio.count {
            try stopIfAsked()
            let count = min(chunk, audio.count - pushed)
            var event: OpaquePointer?
            try audio[pushed..<(pushed + count)].withUnsafeBufferPointer {
                try Self.check(
                    audiocpp_stream_push(
                        session, $0.baseAddress, count, Int32(AudioDecoder.sampleRate), 1,
                        Int64(pushed), &event))
            }
            if let event {
                defer { audiocpp_event_free(event) }
                streamed += try Self.text(of: audiocpp_event_as_result(event))
            }
            pushed += count
            if pushed - (spans.last?.end ?? 0) >= every { spans.append((pushed, streamed)) }
            progress(Double(pushed) / Double(audio.count))
        }
        var result: OpaquePointer?
        defer { audiocpp_result_free(result) }
        try Self.check(audiocpp_stream_finish(session, &result))
        let whole = try Self.text(of: result)
        // Merge final buffered words into the last span when it already ends here.
        if spans.last?.end == audio.count { spans.removeLast() }
        spans.append((audio.count, whole))

        func segment(_ text: Substring, from start: Int, to end: Int) -> Segment? {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty
                ? nil
                : Segment(
                    start: offset + Double(start) / rate, end: offset + Double(end) / rate,
                    text: words)
        }
        guard whole.hasPrefix(streamed) else {
            return segment(Substring(whole), from: 0, to: audio.count).map { [$0] } ?? []
        }
        var segments: [Segment] = []
        var start = 0
        var written = whole.startIndex
        for span in spans {
            let upTo = whole.index(whole.startIndex, offsetBy: span.text.count)
            if let found = segment(whole[written..<upTo], from: start, to: span.end) {
                segments.append(found)
            }
            written = upTo
            start = span.end
        }
        return segments
    }

    private static func text(of result: OpaquePointer?) throws -> String {
        var text: UnsafePointer<CChar>?
        let status = audiocpp_result_text(result, &text, nil)
        if status == AUDIOCPP_ERR_NOT_AVAILABLE { return "" }
        try check(status)
        return text.map { String(cString: $0) } ?? ""
    }

    // MARK: Segments

    /// The segments a family times itself, placed on the recording; else the
    /// sentences the aligner timed; else one segment for the whole window.
    private func segments(of result: OpaquePointer?, in window: Range<Int>) throws -> [Segment] {
        let rate = Double(AudioDecoder.sampleRate)
        let offset = Double(window.lowerBound) / rate
        let length = Double(window.count) / rate
        func time(_ sample: Int64) -> TimeInterval {
            offset + min(max(0, Double(sample) / rate), length)
        }

        let turns = audiocpp_result_speaker_turn_count(result)
        var timed: [Segment] = []
        for index in 0..<audiocpp_result_segment_count(result) {
            var start: Int64 = 0
            var end: Int64 = 0
            var text: UnsafePointer<CChar>?
            try Self.check(audiocpp_result_segment(result, index, &start, &end, nil, &text))
            let words =
                text.map { String(cString: $0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !words.isEmpty else { continue }
            // MOSS gives one speaker turn per segment, in the same order.
            var speaker: UnsafePointer<CChar>?
            if index < turns {
                try Self.check(
                    audiocpp_result_speaker_turn(result, index, nil, nil, &speaker, nil, nil))
            }
            timed.append(
                Segment(
                    start: time(start), end: max(time(start), time(end)), text: words,
                    speaker: speaker.map { String(cString: $0) }))
        }
        if !timed.isEmpty { return timed }

        let words = try Self.text(of: result).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        var aligned: [TimedWords.Word] = []
        for index in 0..<audiocpp_result_word_count(result) {
            var word: UnsafePointer<CChar>?
            var start: Int64 = 0
            var end: Int64 = 0
            try Self.check(audiocpp_result_word(result, index, &word, &start, &end, nil))
            aligned.append(
                TimedWords.Word(
                    text: word.map { String(cString: $0) } ?? "", start: time(start),
                    end: max(time(start), time(end))))
        }
        return TimedWords.sentences(of: words, timedBy: aligned)
            ?? [Segment(start: offset, end: offset + length, text: words)]
    }

    /// The detail of a failure can quote the recording, so it goes to the log
    /// as private and the window shows the code.
    private static func check(_ status: audiocpp_status) throws {
        guard status != AUDIOCPP_OK else { return }
        Log.transcription.error(
            "audio.cpp failed: \(String(cString: audiocpp_last_error()), privacy: .private)")
        throw TranscriptionError.failed(Int32(status.rawValue))
    }
}
