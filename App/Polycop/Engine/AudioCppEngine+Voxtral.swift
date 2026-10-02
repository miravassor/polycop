// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import audiocpp

/// How Voxtral Realtime is streamed, and how its transcript is cut into
/// segments. Values from the model's configuration (`audio_length_per_tok` 8
/// frames of `hop_length` 160 samples, `default_num_delay_tokens` 6) and
/// audio.cpp v0.8.1.
nonisolated extension AudioCppEngine {
    /// The audio one decoder step reads, 80 ms. Pushed one step at a time,
    /// each push after the first half second runs exactly one step, so its
    /// event holds all the text that step wrote; a larger push can run two
    /// steps and return only the second one's text (`audiocpp_stream_push`).
    static let voxtralStep = 1280
    /// Text lags the audio by this much, 480 ms.
    static let voxtralDelay = 6 * voxtralStep
    /// The silence audio.cpp's offline path appends to flush the text still
    /// held back by the delay (`padded_streaming_audio`), 1.36 s. Streaming
    /// appends none, so the last words before each cut would be lost.
    static let voxtralFlush = (6 + 1 + 10) * voxtralStep

    /// Steps without text after which the stream starts again, 5.12 s, as
    /// voxtral.c does for long live input (`voxtral.c`, 64 steps). The decoder
    /// can stop writing in the middle of speech, after an end of sequence that
    /// audio.cpp feeds back like any token, and stay silent to the end of the
    /// stream; a new stream reads normally.
    static let voxtralSilentSteps = 64

    /// Where a stream that has written nothing for `voxtralSilentSteps` starts
    /// again, in samples of the window, or nil to let it run. It starts from
    /// the last text heard, so speech a stalled decoder passed over is read
    /// again, but never before audio already read twice, so in a real silence
    /// it moves on without replaying; and never once the real audio has all
    /// been pushed.
    static func voxtralRestart(
        heard: Int, lastText: Int, replayedTo: Int, pushed: Int, audioCount: Int
    ) -> Int? {
        guard heard - lastText >= voxtralSilentSteps * voxtralStep, pushed < audioCount else {
            return nil
        }
        return min(max(lastText, replayedTo), pushed)
    }

    /// Pushes the window to Voxtral one step at a time, as a live input
    /// reaches audiocpp_cli, then the silence that flushes its last words.
    /// The text read by the end of every 30 seconds of audio, less the delay,
    /// cuts the final transcript into segments. A stream silent for too long
    /// starts again (`voxtralRestart`); the streams' texts follow one another.
    /// Runs on the engine's queue, which owns `session`.
    static func streamVoxtral(
        to session: OpaquePointer, _ audio: [Float], _ request: OpaquePointer,
        from offset: TimeInterval,
        until stopIfAsked: () throws -> Void, progress: (Double) -> Void
    ) throws -> [Segment] {
        let padded = audio + [Float](repeating: 0, count: voxtralFlush)
        let span = Int(AudioCppProfile.streamedSegment * Double(AudioDecoder.sampleRate))
        try check(audiocpp_stream_start(session, request))
        var marks: [(end: Int, read: Int)] = []
        var streamed: [UInt8] = []
        var pushed = 0
        // Where the current stream's audio and text start, the audio heard
        // at the last text, how far audio went before the last restart, and
        // the furthest progress shown, which a replay does not take back.
        var origin = 0
        var textStart = 0
        var lastText = 0
        var replayedTo = 0
        var shown = 0.0
        while pushed < padded.count {
            do {
                try stopIfAsked()
            } catch {
                throw StoppedWindow(
                    segments: finishedSpans(of: streamed, marks: marks, from: offset))
            }
            let count = min(voxtralStep, padded.count - pushed)
            let piece = try push(
                padded[pushed..<(pushed + count)], to: session, at: pushed - origin)
            pushed += count
            let heard = min(audio.count, max(origin, pushed - voxtralDelay))
            if !piece.isEmpty {
                append(piece, to: &streamed, streamStart: &textStart)
                lastText = heard
            }
            if heard - (marks.last?.end ?? 0) >= span { marks.append((heard, streamed.count)) }
            shown = max(shown, Double(heard) / Double(audio.count))
            progress(shown)
            if let restart = voxtralRestart(
                heard: heard, lastText: lastText, replayedTo: replayedTo, pushed: pushed,
                audioCount: audio.count)
            {
                replayedTo = pushed
                origin = restart
                pushed = restart
                lastText = restart
                textStart = streamed.count
                try check(audiocpp_stream_start(session, request))
            }
        }
        var result: OpaquePointer?
        defer { audiocpp_result_free(result) }
        try check(audiocpp_stream_finish(session, &result))
        // The final text of the last stream replaces what it streamed.
        let transcript = Array(streamed[..<textStart]) + (try bytes(of: result))
        return streamedSegments(
            of: transcript, streamed: streamed, marks: marks, lasting: audio.count, from: offset)
    }

    /// The spans a stopped window had read to their end, as segments. The
    /// text stops at its last space, since the word read last may not be
    /// whole yet.
    static func finishedSpans(
        of streamed: [UInt8], marks: [(end: Int, read: Int)], from offset: TimeInterval
    ) -> [Segment] {
        guard let last = marks.last else { return [] }
        var read = min(last.read, streamed.count)
        while read > 0, !isSpace(streamed[read - 1]) { read -= 1 }
        let text = Array(streamed[..<read])
        return streamedSegments(
            of: text, streamed: text, marks: marks, lasting: last.end, from: offset)
    }

    /// Adds a step's text. The first words of a new stream are kept apart
    /// from the last ones of the stream before, which moves where the new
    /// stream's text starts.
    private static func append(
        _ piece: [UInt8], to streamed: inout [UInt8], streamStart: inout Int
    ) {
        if streamStart > 0, streamed.count == streamStart, let last = streamed.last,
            let first = piece.first, !isSpace(last), !isSpace(first)
        {
            streamed.append(0x20)
            streamStart += 1
        }
        streamed += piece
    }

    /// Pushes one step of audio, `sample` samples into the current stream,
    /// and returns the text that step wrote.
    private static func push(
        _ step: ArraySlice<Float>, to session: OpaquePointer, at sample: Int
    ) throws -> [UInt8] {
        var event: OpaquePointer?
        try step.withUnsafeBufferPointer {
            try check(
                audiocpp_stream_push(
                    session, $0.baseAddress, $0.count, Int32(AudioDecoder.sampleRate), 1,
                    Int64(sample), &event))
        }
        guard let event else { return [] }
        defer { audiocpp_event_free(event) }
        return try bytes(of: audiocpp_event_as_result(event))
    }

    /// Cuts Voxtral's transcript of a window into the spans read while it
    /// streamed. Each mark pairs where a span ends, in samples of the window,
    /// with how many bytes of text had been read by then; a mark inside a
    /// word moves to the end of that word. When the bytes read are not the
    /// start of the transcript, the window is one segment.
    static func streamedSegments(
        of transcript: [UInt8], streamed: [UInt8], marks: [(end: Int, read: Int)],
        lasting length: Int, from offset: TimeInterval
    ) -> [Segment] {
        let rate = Double(AudioDecoder.sampleRate)
        func segment(_ bytes: ArraySlice<UInt8>, from start: Int, to end: Int) -> Segment? {
            let words = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty
                ? nil
                : Segment(
                    start: offset + Double(start) / rate, end: offset + Double(end) / rate,
                    text: words)
        }
        guard transcript.starts(with: streamed) else {
            return segment(transcript[...], from: 0, to: length).map { [$0] } ?? []
        }
        var segments: [Segment] = []
        var start = 0
        var written = 0
        for mark in marks where mark.end > start && mark.end < length {
            var cut = min(max(mark.read, written), transcript.count)
            while cut < transcript.count, !isSpace(transcript[cut]) { cut += 1 }
            if let found = segment(transcript[written..<cut], from: start, to: mark.end) {
                segments.append(found)
            }
            written = cut
            start = mark.end
        }
        if let last = segment(transcript[written...], from: start, to: length) {
            segments.append(last)
        }
        return segments
    }

    /// A space or a line break, never a byte inside a character.
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
    }
}
