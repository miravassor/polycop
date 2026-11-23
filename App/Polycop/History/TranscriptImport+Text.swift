// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension TranscriptImport {
    static func subtitles(_ raw: String) throws -> Parsed {
        let text = tidied(raw)
        let vtt = text.hasPrefix("WEBVTT")
        let blocks = text.split(separator: /\n(?:[ \t]*+\n)++/)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var cues: [Cue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(
                String.init)
            guard let first = lines.first else { continue }
            if vtt
                && (first == "WEBVTT" || first.hasPrefix("WEBVTT ") || first == "NOTE"
                    || first.hasPrefix("NOTE ") || first == "STYLE" || first == "REGION")
            {
                guard !block.contains("-->") else { throw Failure.invalidTimes }
                continue
            }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }), timing <= 1,
                timing + 1 < lines.count
            else { throw Failure.invalidTimes }
            let (start, end) = try interval(lines[timing])
            cues.append(
                Cue(start: start, end: end, text: lines[(timing + 1)...].joined(separator: "\n")))
        }
        return Parsed(cues: cues)
    }

    static func plainText(_ raw: String) throws -> Parsed {
        let text = tidied(raw)
        let mossStart = /\[\d++(?:\.\d++)?\]\s*+\[S\d++\]/
        return text.prefixMatch(of: mossStart) != nil
            ? try moss(text) : try parseTimestamped(text)
    }

    static func timestamped(_ raw: String) throws -> Parsed {
        try parseTimestamped(tidied(raw))
    }

    private static func tidied(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func interval(_ text: String) throws -> (Double, Double) {
        let parts = text.components(separatedBy: "-->")
        guard parts.count == 2, let end = parts[1].split(whereSeparator: \.isWhitespace).first
        else { throw Failure.invalidTimes }
        return (try clock(parts[0]), try clock(String(end)))
    }

    private static func parseTimestamped(_ text: String) throws -> Parsed {
        var cues: [Cue] = []
        var timing: (start: Double, end: Double?)?
        var lines: [String] = []
        func appendCue() {
            guard let timing else { return }
            cues.append(
                Cue(
                    start: timing.start, end: timing.end,
                    text: lines.joined(separator: "\n").trimmingCharacters(
                        in: .whitespacesAndNewlines)))
            lines.removeAll(keepingCapacity: true)
        }
        // Lines before the first time, such as a title and a date, are left
        // out; a file with no time at all imports nothing and is refused. The
        // first time decides the style, bracketed or bare as recorder apps
        // write it ("00:03:30 Bonjour"), so text that opens on a time is not
        // read as one.
        var isBracketed: Bool?
        // Possessive whitespace prevents quadratic backtracking when a line
        // holds a Unicode line separator such as U+2028 after spaces.
        let bareLine = /(\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d++)?)(?:\s++(.*))?/
        for line in text.components(separatedBy: "\n") {
            if isBracketed != true, let bare = line.wholeMatch(of: bareLine) {
                isBracketed = false
                appendCue()
                timing = (try clock(String(bare.output.1)), nil)
                if let text = bare.output.2 {
                    lines.append(String(text).trimmingCharacters(in: .whitespaces))
                }
            } else if isBracketed != false, line.hasPrefix("["),
                let close = line.firstIndex(of: "]")
            {
                isBracketed = true
                appendCue()
                let stamp = String(line[line.index(after: line.startIndex)..<close])
                timing = stamp.contains("-->") ? try interval(stamp) : (try clock(stamp), nil)
                lines.append(
                    String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces))
            } else if timing != nil {
                lines.append(line)
            }
        }
        appendCue()
        return Parsed(cues: cues)
    }

    private static func moss(_ text: String) throws -> Parsed {
        let passage =
            /\[(\d++(?:\.\d++)?)\]\s*+\[(S\d++)\](.*?)\[(\d++(?:\.\d++)?)\]/
            .dotMatchesNewlines()
        var rest = text[...]
        var cues: [Cue] = []
        while let match = rest.firstMatch(of: passage) {
            let (_, startText, speaker, words, endText) = match.output
            guard
                rest[..<match.range.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let start = Double(startText),
                let end = Double(endText)
            else { throw Failure.invalidTimes }
            cues.append(
                Cue(
                    start: start, end: end,
                    text: words.trimmingCharacters(in: .whitespacesAndNewlines),
                    speaker: String(speaker)))
            rest = rest[match.range.upperBound...]
        }
        guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidTimes
        }
        return Parsed(cues: cues)
    }
}
