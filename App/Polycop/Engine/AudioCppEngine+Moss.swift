// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import audiocpp
import os

/// How MOSS-Transcribe-Diarize's text becomes segments. The app reads the
/// text itself rather than audio.cpp's result, which a window stopped by its
/// token limit never gets.
nonisolated extension AudioCppEngine {
    /// MOSS's own instruction, as audio.cpp and the official repository write
    /// it; hotwords follow it in the official form (`examples/prompts.md`).
    static let mossInstruction =
        "请将音频转写为文本，每一段需以起始时间戳和说话人编号（[S01]、[S02]、[S03]…）开头，"
        + "正文为对应的语音内容，并在段末标注结束时间戳，以清晰标明该段语音范围。"

    /// Reads MOSS's text token by token. The times it writes show how far
    /// into the window it has reached, which is the progress.
    ///
    /// audio.cpp fails a window that reaches `max_tokens` before its end,
    /// usually one repeating a phrase. Only that window is cut short: the
    /// passages it finished are kept, and the next window runs.
    /// Runs on the engine's queue, which owns `session`.
    static func readMoss(
        from session: OpaquePointer, _ request: OpaquePointer, lasting length: TimeInterval,
        until stopIfAsked: () throws -> Void, progress: (Double) -> Void
    ) throws -> (text: String, isComplete: Bool) {
        try check(audiocpp_stream_start(session, request))
        var text = ""
        while true {
            try stopIfAsked()
            var event: OpaquePointer?
            let status = audiocpp_stream_next_event(session, &event)
            if status == AUDIOCPP_ERR_RUNTIME,
                String(cString: audiocpp_last_error()).contains("max_tokens")
            {
                let reached = lastTime(in: text) ?? 0
                Log.transcription.error(
                    "MOSS reached max_tokens, window cut at \(reached, privacy: .public) s")
                return (text, false)
            }
            try check(status)
            guard let event else { break }
            defer { audiocpp_event_free(event) }
            text += try Self.text(of: audiocpp_event_as_result(event))
            if text.hasSuffix("]"), let reached = lastTime(in: text), length > 0 {
                progress(min(1, reached / length))
            }
        }
        return (text, true)
    }

    /// MOSS's passages as segments on the recording, for a window starting at
    /// `offset` and lasting `length` seconds. A passage is "[start][Sxx] text
    /// [end]" followed by the next one or the end, read as audio.cpp v0.8.1
    /// reads it (`parse_result`): one with no text, or ending before it
    /// starts, is skipped. A passage left unfinished is never kept. Text with
    /// no passage at all is one segment for the window, its markup removed,
    /// unless the window was stopped before its end.
    static func mossSegments(
        in text: String, from offset: TimeInterval, lasting length: TimeInterval,
        isComplete: Bool
    ) -> [Segment] {
        // audio.cpp's pattern, spread over lines, where spaces do not count.
        let passage =
            #/
            \[ ([0-9]+(?:\.[0-9]*)?|\.[0-9]+) \] \s* \[ (S[0-9]+) \]
            ([\s\S]*?) \[ ([0-9]+(?:\.[0-9]*)?|\.[0-9]+) \] (?=\s*(?:\[|$))
            /#
        func place(_ seconds: Double) -> TimeInterval { offset + min(max(0, seconds), length) }
        var segments: [Segment] = []
        for match in text.matches(of: passage) {
            let (_, start, speaker, words, end) = match.output
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = Double(start), let end = Double(end), end >= start, !trimmed.isEmpty
            else { continue }
            segments.append(
                Segment(
                    start: place(start), end: place(end), text: trimmed,
                    speaker: String(speaker)))
        }
        guard segments.isEmpty, isComplete else { return segments }
        let bare = text.replacing(#/\[[^\]]*\]/#, with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return bare.isEmpty ? [] : [Segment(start: offset, end: offset + length, text: bare)]
    }

    /// The last time a MOSS transcript has written, as in "[12.34]".
    static func lastTime(in text: String) -> TimeInterval? {
        guard let close = text.lastIndex(of: "]"),
            let open = text[..<close].lastIndex(of: "[")
        else { return nil }
        return TimeInterval(text[text.index(after: open)..<close])
    }
}
