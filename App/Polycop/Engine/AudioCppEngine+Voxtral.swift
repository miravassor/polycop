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

    /// Pushes the window to Voxtral one step at a time, as a live input
    /// reaches audiocpp_cli, then the silence that flushes its last words.
    /// The text read by the end of every 30 seconds of audio, less the delay,
    /// cuts the final transcript into segments.
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
        while pushed < padded.count {
            try stopIfAsked()
            let count = min(voxtralStep, padded.count - pushed)
            var event: OpaquePointer?
            try padded[pushed..<(pushed + count)].withUnsafeBufferPointer {
                try check(
                    audiocpp_stream_push(
                        session, $0.baseAddress, count, Int32(AudioDecoder.sampleRate), 1,
                        Int64(pushed), &event))
            }
            if let event {
                defer { audiocpp_event_free(event) }
                streamed += try bytes(of: audiocpp_event_as_result(event))
            }
            pushed += count
            let heard = min(audio.count, max(0, pushed - voxtralDelay))
            if heard - (marks.last?.end ?? 0) >= span { marks.append((heard, streamed.count)) }
            progress(Double(heard) / Double(audio.count))
        }
        var result: OpaquePointer?
        defer { audiocpp_result_free(result) }
        try check(audiocpp_stream_finish(session, &result))
        return streamedSegments(
            of: try bytes(of: result), streamed: streamed, marks: marks,
            lasting: audio.count, from: offset)
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
