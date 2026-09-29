// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How MOSS-Transcribe-Diarize's text becomes segments. The app reads the
/// text itself rather than audio.cpp's result, which a window stopped by its
/// token limit never gets.
nonisolated extension AudioCppEngine {
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
