// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import whisper

/// Runs whisper.cpp on one loaded model.
///
/// One context is not thread safe and a transcription blocks for minutes, so
/// the work runs on this serial queue rather than on the concurrency pool. That
/// queue is what makes the class safe to share.
nonisolated final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    private let context: OpaquePointer
    private let queue = DispatchQueue(
        label: "io.github.miravassor.Polycop.engine", qos: .userInitiated)

    /// Loading reads gigabytes of weights and prepares Metal. It runs off the
    /// calling actor, so the window keeps responding while a model opens.
    /// Catalogue entries provide the measured peak for the memory check, and
    /// their contents are proven before the native parser sees them.
    static func load(model: URL, expecting catalogued: Model? = nil) async throws -> WhisperEngine {
        let catalogued = catalogued ?? ModelCatalog.model(model.lastPathComponent)
        try refuse(model, catalogued)
        guard let catalogued, catalogued.engine == .whisper else {
            throw ModelStore.ImportError.unrecognized
        }
        try await ModelStore.verify(catalogued, at: model)
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            loadingQueue.async {
                do {
                    continuation.resume(
                        returning: try WhisperEngine(model: model, expecting: catalogued))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let loadingQueue = DispatchQueue(
        label: "io.github.miravassor.Polycop.engine.load", qos: .userInitiated)

    /// Checks what whisper.cpp cannot report. It returns a null context for a
    /// missing file, a damaged one and a Mac short of memory alike. The first
    /// two are told apart before the call, and the message names the rest.
    private init(model: URL, expecting catalogued: Model? = nil) throws {
        try WhisperEngine.refuse(model, catalogued)

        var parameters = whisper_context_default_params()
        parameters.use_gpu = true
        parameters.flash_attn = true
        guard
            let context = whisper_init_from_file_with_params(
                model.path(percentEncoded: false), parameters)
        else {
            throw TranscriptionError.modelUnreadable(model)
        }
        self.context = context
    }

    /// Every call on the queue holds the engine, so it cannot be freed while
    /// whisper_full runs. Waiting on the queue here would crash instead,
    /// since the last reference can drop as a call ends, on that same queue.
    deinit {
        whisper_free(context)
    }

    /// How many tokens this model reads for the text, counted by its own
    /// tokenizer. It runs on the queue, so it waits behind a transcription.
    /// Each call logs "too many resulting tokens", because whisper.cpp counts
    /// by tokenizing into an empty buffer; that log line is not a failure.
    func tokenCount(of text: String) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Int(whisper_token_count(self.context, text)))
            }
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// Transcribes 16 kHz mono samples, reporting progress and each segment as
    /// it is decoded. Cancelling the task stops the computation.
    ///
    /// `from` continues a paused transcription. The audio before it is sliced
    /// off rather than passed as `offset_ms`, so the silence detector only sees
    /// what is transcribed. No decoding context crosses the seam.
    func transcribe(
        samples: [Float],
        settings: DecodingSettings,
        from start: TimeInterval = 0,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        onSegment: @escaping @Sendable (Segment) -> Void = { _ in }
    ) async throws -> [Segment] {
        let first = try Self.firstSample(at: start, count: samples.count)
        // Given no samples, whisper.cpp keeps the previous spectrogram and
        // transcribes it again (`whisper_full_with_state`, v1.9.4).
        guard first < samples.count else {
            try Task.checkCancellation()
            return []
        }
        let shift = Double(first) / Double(WHISPER_SAMPLE_RATE)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let segments = try self.decode(
                            samples[first...], settings, cancelled, onProgress,
                            { onSegment($0.shifted(by: shift)) })
                        continuation.resume(returning: segments.map { $0.shifted(by: shift) })
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// The stretches of speech the detector hears, in seconds. Asked of the
    /// detector rather than read from the context, which keeps the previous
    /// recording's stretches when it finds none (`whisper_vad`, v1.9.4).
    ///
    /// An empty result means it heard no speech. A detector that cannot run
    /// throws instead of reporting silence, since silence would wrongly claim
    /// the whole recording was left out of the transcript.
    static func speech(in samples: [Float], settings: DecodingSettings) async throws
        -> [ClosedRange<TimeInterval>]
    {
        // The detector has no abort callback, so a stop is honoured before it starts.
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            detectingQueue.async {
                do {
                    continuation.resume(returning: try detectSpeech(samples, settings))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let detectingQueue = DispatchQueue(
        label: "io.github.miravassor.Polycop.detector", qos: .userInitiated)

    private static func detectSpeech(_ samples: [Float], _ settings: DecodingSettings)
        throws -> [ClosedRange<TimeInterval>]
    {
        guard let model = settings.voiceActivityModel,
            let detector = whisper_vad_init_from_file_with_params(
                model.path(percentEncoded: false), whisper_vad_default_context_params())
        else {
            Log.transcription.error("the silence detector could not be opened")
            throw TranscriptionError.detectorUnavailable
        }
        defer { whisper_vad_free(detector) }

        var parameters = whisper_vad_default_params()
        parameters.threshold = settings.voiceActivityThreshold
        guard
            let found = samples.withUnsafeBufferPointer({
                whisper_vad_segments_from_samples(
                    detector, parameters, $0.baseAddress, Int32($0.count))
            })
        else {
            Log.transcription.error("the silence detector failed on this recording")
            throw TranscriptionError.detectorUnavailable
        }
        defer { whisper_vad_free_segments(found) }

        // Counted in hundredths of a second, like segment times. The model also
        // hears `samples_overlap` past each stretch but the last, which
        // whisper.cpp adds when joining them.
        let count = whisper_vad_segments_n_segments(found)
        let overlap = TimeInterval(parameters.samples_overlap)
        return (0..<count).map { index in
            let start = TimeInterval(whisper_vad_segments_get_segment_t0(found, index)) / 100
            let end = TimeInterval(whisper_vad_segments_get_segment_t1(found, index)) / 100
            return start...max(start, end + (index < count - 1 ? overlap : 0))
        }
    }

    /// The blocking call, on the queue. Handlers reach the C callbacks through
    /// an unretained pointer that stays valid for the whole call.
    private func decode(
        _ samples: ArraySlice<Float>,
        _ settings: DecodingSettings,
        _ cancelled: OSAllocatedUnfairLock<Bool>,
        _ onProgress: @escaping @Sendable (Double) -> Void,
        _ onSegment: @escaping @Sendable (Segment) -> Void
    ) throws -> [Segment] {
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)

        // These strings must outlive the call, so they are copied, not bridged.
        let language = strdup(settings.language)
        let prompt = settings.prompt.map { strdup($0) }
        let voiceActivityModel = settings.voiceActivityModel.map {
            strdup($0.path(percentEncoded: false))
        }
        defer {
            free(language)
            prompt.map { free($0) }
            voiceActivityModel.map { free($0) }
        }

        parameters.language = language.map { UnsafePointer($0) }
        parameters.n_threads = settings.threads
        parameters.beam_search.beam_size = settings.beamSize
        parameters.greedy.best_of = settings.bestOf
        parameters.temperature = settings.temperature
        parameters.temperature_inc = settings.temperatureIncrement
        parameters.entropy_thold = settings.entropyThreshold
        parameters.logprob_thold = settings.logProbabilityThreshold
        parameters.no_speech_thold = settings.noSpeechThreshold
        parameters.n_max_text_ctx = settings.textContext
        parameters.initial_prompt = prompt.flatMap { UnsafePointer($0) }
        parameters.carry_initial_prompt = prompt != nil
        parameters.vad = settings.voiceActivityDetection
        parameters.vad_model_path = voiceActivityModel.flatMap { UnsafePointer($0) }
        // Without this the toggle would silently use the library default of 0.5.
        parameters.vad_params.threshold = settings.voiceActivityThreshold

        // whisper.cpp prints to standard output otherwise; the app uses the callbacks.
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        // Word times and probabilities, for playing from a word and marking
        // the uncertain ones.
        parameters.token_timestamps = true
        parameters.print_special = false

        let handlers = Handlers(progress: onProgress, segment: onSegment, cancelled: cancelled)
        let pointer = Unmanaged.passUnretained(handlers).toOpaque()

        parameters.progress_callback = { _, _, progress, data in
            guard let data else { return }
            Unmanaged<Handlers>.fromOpaque(data).takeUnretainedValue().progress(
                Double(progress) / 100)
        }
        parameters.progress_callback_user_data = pointer

        parameters.new_segment_callback = { context, state, count, data in
            guard let data, let context, let state else { return }
            let handlers = Unmanaged<Handlers>.fromOpaque(data).takeUnretainedValue()
            let total = whisper_full_n_segments_from_state(state)
            for index in (total - count)..<total {
                handlers.segment(
                    WhisperEngine.segment(context: context, state: state, index: index))
            }
        }
        parameters.new_segment_callback_user_data = pointer

        // Returning true aborts the computation.
        parameters.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<Handlers>.fromOpaque(data).takeUnretainedValue().cancelled.withLock {
                $0
            }
        }
        parameters.abort_callback_user_data = pointer

        // The callbacks read handlers through an unretained pointer, so it has
        // to stay alive for the whole call.
        let code = withExtendedLifetime(handlers) {
            samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, parameters, buffer.baseAddress, Int32(buffer.count))
            }
        }
        if cancelled.withLock({ $0 }) {
            throw CancellationError()
        }
        guard code == 0 else {
            throw TranscriptionError.failed(code)
        }

        let end = whisper_token_eot(context)
        return (0..<whisper_full_n_segments(context)).map { index in
            Segment(
                start: TimeInterval(whisper_full_get_segment_t0(context, index)) / 100,
                end: TimeInterval(whisper_full_get_segment_t1(context, index)) / 100,
                text: String(cString: whisper_full_get_segment_text(context, index)),
                words: Self.words(
                    from: (0..<whisper_full_n_tokens(context, index)).compactMap { token in
                        guard whisper_full_get_token_id(context, index, token) < end else {
                            return nil
                        }
                        return Token(
                            bytes: Self.bytes(
                                of: whisper_full_get_token_text(context, index, token)),
                            probability: whisper_full_get_token_p(context, index, token),
                            start: whisper_full_get_token_t0(context, index, token),
                            end: whisper_full_get_token_t1(context, index, token))
                    })
            )
        }
    }

    /// Times are counted in hundredths of a second.
    private static func segment(
        context: OpaquePointer, state: OpaquePointer, index: Int32
    ) -> Segment {
        let end = whisper_token_eot(context)
        return Segment(
            start: TimeInterval(whisper_full_get_segment_t0_from_state(state, index)) / 100,
            end: TimeInterval(whisper_full_get_segment_t1_from_state(state, index)) / 100,
            text: String(cString: whisper_full_get_segment_text_from_state(state, index)),
            words: words(
                from: (0..<whisper_full_n_tokens_from_state(state, index)).compactMap { token in
                    guard whisper_full_get_token_id_from_state(state, index, token) < end else {
                        return nil
                    }
                    return Token(
                        bytes: bytes(
                            of: whisper_full_get_token_text_from_state(
                                context, state, index, token)),
                        probability: whisper_full_get_token_p_from_state(state, index, token),
                        start: whisper_full_get_token_t0_from_state(state, index, token),
                        end: whisper_full_get_token_t1_from_state(state, index, token))
                })
        )
    }

    /// One token as whisper.cpp reports it, times in hundredths of a second
    /// on the recording's timeline. Bytes rather than text: a character can be
    /// split between two tokens, and only the whole word decodes.
    struct Token {
        let bytes: [UInt8]
        let probability: Float
        let start: Int64
        let end: Int64
    }

    /// Tokens are pieces of words, and a new word starts with a space. A word's
    /// confidence is the mean probability of its tokens.
    static func words(from tokens: [Token]) -> [Segment.Word] {
        var groups: [[Token]] = []
        for token in tokens where !token.bytes.isEmpty {
            if token.bytes.first == UInt8(ascii: " ") || groups.isEmpty {
                groups.append([token])
            } else {
                groups[groups.count - 1].append(token)
            }
        }
        return groups.compactMap { group in
            let text = String(decoding: group.flatMap(\.bytes), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let first = group.first, let last = group.last else { return nil }
            return Segment.Word(
                text: text, start: TimeInterval(first.start) / 100,
                end: TimeInterval(max(first.start, last.end)) / 100,
                confidence: group.map(\.probability).reduce(0, +) / Float(group.count))
        }
    }

    private static func bytes(of text: UnsafePointer<CChar>) -> [UInt8] {
        Array(UnsafeRawBufferPointer(start: text, count: strlen(text)))
    }

    /// What the C callbacks need, reachable through one pointer.
    private final class Handlers {
        let progress: @Sendable (Double) -> Void
        let segment: @Sendable (Segment) -> Void
        let cancelled: OSAllocatedUnfairLock<Bool>

        init(
            progress: @escaping @Sendable (Double) -> Void,
            segment: @escaping @Sendable (Segment) -> Void,
            cancelled: OSAllocatedUnfairLock<Bool>
        ) {
            self.progress = progress
            self.segment = segment
            self.cancelled = cancelled
        }
    }
}
