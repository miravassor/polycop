// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Parses an externally authored transcript (SRT, VTT, timestamped TXT or Word
/// document, or a Whisper/audio.cpp JSON export) into cues for `Entry`.
nonisolated enum TranscriptImport {
    static let maximumBytes = 5 << 20

    enum Failure: LocalizedError {
        case unsupported
        case tooLarge
        case invalidTimes
        case audioMismatch

        var errorDescription: String? {
            switch self {
            case .unsupported:
                String(
                    localized:
                        "Choose a timestamped TXT or Word document, an SRT or VTT file, or a supported Whisper/audio.cpp JSON file. Plain text without timestamps cannot be aligned yet."
                )
            case .tooLarge:
                String(localized: "The transcript exceeds the 5 MB import limit.")
            case .invalidTimes:
                String(
                    localized:
                        "The transcript contains missing, invalid or out-of-order timestamps. No transcript was imported."
                )
            case .audioMismatch:
                String(
                    localized:
                        "The transcript extends beyond this recording. Choose the matching audio or check the timestamp units."
                )
            }
        }
    }

    struct Cue {
        let start: TimeInterval
        let end: TimeInterval?
        let text: String
        var speaker: String?
    }

    struct Parsed {
        let cues: [Cue]
        var isWordLevel = false

        /// Builds an entry from these cues, matched against the recording's duration.
        func entry(recording: URL, duration: TimeInterval, source: String) throws -> Entry {
            guard duration.isFinite, duration > 0 else { throw Failure.audioMismatch }
            guard cues.allSatisfy({ $0.start < duration && ($0.end ?? $0.start) <= duration + 0.5 })
            else {
                throw Failure.audioMismatch
            }
            let segments = cues.enumerated().map { index, cue in
                Segment(
                    start: cue.start,
                    end: min(
                        duration,
                        cue.end ?? (index + 1 < cues.count ? cues[index + 1].start : duration)),
                    text: cue.text, speaker: cue.speaker)
            }
            var entry = Entry(
                recording: recording, modelFile: "imported", glossary: nil,
                skipsSilence: false, subtitles: false)
            entry.importSource = source
            entry.title = (source as NSString).deletingPathExtension
            entry.duration = duration
            entry.decoded = segments
            entry.showsCredits = true
            entry.paragraphs =
                isWordLevel
                ? Transcript.paragraphs(segments)
                : segments.map {
                    let label = Transcript.label(of: $0.speaker).map { $0 + " " } ?? ""
                    return Transcript.Paragraph(
                        start: Int(($0.start * 1000).rounded()), text: label + $0.text)
                }
            entry.originalParagraphs = entry.paragraphs
            entry.sentenceTimes = cues.allSatisfy { $0.end != nil }
            entry.state = .finished
            return entry
        }
    }

    @concurrent
    static func read(_ file: URL) async throws -> Parsed {
        try Task.checkCancellation()
        guard file.isFileURL,
            try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else {
            throw Failure.unsupported
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let result = try parse(data, extension: file.pathExtension)
        try Task.checkCancellation()
        return result
    }

    static func parse(_ data: Data, extension suffix: String) throws -> Parsed {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let parsed: Parsed
        if suffix.lowercased() == "json" {
            parsed = try json(data)
        } else if suffix.lowercased() == "docx" {
            parsed = try timestamped(tidied(wordText(data)))
        } else {
            // Older subtitle tools save French in Windows Latin.
            guard let decoded = TextFile.decode(data), !decoded.contains("\u{0}") else {
                throw Failure.unsupported
            }
            let text = tidied(decoded)
            switch suffix.lowercased() {
            case "srt", "vtt": parsed = try subtitles(text)
            case "txt":
                parsed =
                    text.range(of: #"^\[\d+(?:\.\d+)?\]\s*\[S\d+\]"#, options: .regularExpression)
                        != nil
                    ? try moss(text) : try timestamped(text)
            default: throw Failure.unsupported
            }
        }
        try validate(parsed.cues)
        return parsed
    }

    private static func tidied(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
    }

    /// The text of a Word document, as recorder apps export their transcripts.
    /// The system importer builds it whole, so the text is checked for size
    /// after it expands.
    private static func wordText(_ data: Data) throws -> String {
        guard
            let text = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil
            ).string
        else { throw Failure.unsupported }
        guard text.utf8.count <= maximumBytes else { throw Failure.tooLarge }
        return text
    }

    private static func validate(_ cues: [Cue]) throws {
        guard !cues.isEmpty, cues.count <= 50_000 else { throw Failure.unsupported }
        guard
            cues.allSatisfy({ cue in
                cue.start.isFinite && cue.start >= 0 && cue.start <= AudioDecoder.longestRecording
                    && (cue.end.map {
                        $0.isFinite && $0 >= cue.start && $0 <= AudioDecoder.longestRecording
                    } ?? true)
                    && !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }), zip(cues, cues.dropFirst()).allSatisfy({ $0.start <= $1.start })
        else {
            throw Failure.invalidTimes
        }
    }

    private static func clock(_ string: String) throws -> Double {
        let parts = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(
            of: ",", with: "."
        ).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
            let last = parts.last, let seconds = Double(last), seconds.isFinite, seconds >= 0,
            seconds < 60,
            let minutes = Int(parts[parts.count - 2]), minutes >= 0, minutes < 60
        else { throw Failure.invalidTimes }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours, hours >= 0, hours <= 4 else { throw Failure.invalidTimes }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    private static func interval(_ text: String) throws -> (Double, Double) {
        let parts = text.components(separatedBy: "-->")
        guard parts.count == 2, let end = parts[1].split(whereSeparator: \.isWhitespace).first
        else { throw Failure.invalidTimes }
        return (try clock(parts[0]), try clock(String(end)))
    }

    private static func subtitles(_ text: String) throws -> Parsed {
        let vtt = text.hasPrefix("WEBVTT")
        let blocks = text.replacingOccurrences(
            of: #"\n[ \t]+\n"#, with: "\n\n", options: .regularExpression
        )
        .components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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

    private static func timestamped(_ text: String) throws -> Parsed {
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
        for line in text.components(separatedBy: "\n") {
            if isBracketed != true,
                let bare = line.wholeMatch(
                    of: /(\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d+)?)(?:\s+(.*))?/)
            {
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
                if stamp.contains("-->") {
                    timing = try interval(stamp)
                } else {
                    timing = (try clock(stamp), nil)
                }
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
        let expression = try NSRegularExpression(
            pattern: #"\[(\d+(?:\.\d+)?)\]\s*\[(S\d+)\](.*?)\[(\d+(?:\.\d+)?)\]"#,
            options: .dotMatchesLineSeparators)
        let string = text as NSString
        var reached = 0
        var cues: [Cue] = []
        for match in expression.matches(
            in: text, range: NSRange(location: 0, length: string.length))
        {
            guard
                string.substring(
                    with: NSRange(location: reached, length: match.range.location - reached)
                ).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let start = Double(string.substring(with: match.range(at: 1))),
                let end = Double(string.substring(with: match.range(at: 4)))
            else { throw Failure.invalidTimes }
            cues.append(
                Cue(
                    start: start, end: end,
                    text: string.substring(with: match.range(at: 3)).trimmingCharacters(
                        in: .whitespacesAndNewlines),
                    speaker: string.substring(with: match.range(at: 2))))
            reached = NSMaxRange(match.range)
        }
        guard
            string.substring(from: reached).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Failure.invalidTimes }
        return Parsed(cues: cues)
    }

    private static func json(_ data: Data) throws -> Parsed {
        let value = try JSONSerialization.jsonObject(with: data)
        let root = value as? [String: Any]
        guard let rows = rows(in: value, root: root) else { throw Failure.unsupported }
        let sampleRate = try root?["sample_rate"].map { try number($0) } ?? 16000
        guard sampleRate >= 1000, sampleRate <= 384000 else { throw Failure.invalidTimes }
        let cues = try rows.map { try cue(from: $0, sampleRate: sampleRate) }
        // Validate individual words before sentence grouping can hide invalid times.
        try validate(cues)
        let isWordLevel = rows.first?["word"] != nil || root?["time_stamps"] != nil
        if isWordLevel, let text = root?["text"] as? String {
            guard
                let sentences = TimedWords.sentences(
                    of: text,
                    timedBy: cues.map {
                        TimedWords.Word(text: $0.text, start: $0.start, end: $0.end ?? $0.start)
                    })
            else { throw Failure.invalidTimes }
            return Parsed(cues: sentences.map { Cue(start: $0.start, end: $0.end, text: $0.text) })
        }
        return Parsed(cues: cues, isWordLevel: isWordLevel)
    }

    /// The rows a Whisper or audio.cpp JSON export keeps its cues under,
    /// whichever key the exporter used.
    private static func rows(in value: Any, root: [String: Any]?) -> [[String: Any]]? {
        value as? [[String: Any]] ?? root?["transcription"] as? [[String: Any]]
            ?? root?["segments"] as? [[String: Any]] ?? root?["speaker_turns"] as? [[String: Any]]
            ?? root?["words"] as? [[String: Any]] ?? root?["time_stamps"] as? [[String: Any]]
    }

    private static func number(_ value: Any?) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.doubleValue.isFinite
        else { throw Failure.invalidTimes }
        return value.doubleValue
    }

    /// One cue from a row, in whichever timing convention the export uses
    /// (millisecond offsets, sample counts, a clock string, or seconds).
    private static func cue(from row: [String: Any], sampleRate: Double) throws -> Cue {
        guard let text = row["text"] as? String ?? row["word"] as? String else {
            throw Failure.unsupported
        }
        let start: Double
        let end: Double
        if let offsets = row["offsets"] as? [String: Any] {
            start = try number(offsets["from"]) / 1000
            end = try number(offsets["to"]) / 1000
        } else if row["start_sample"] != nil {
            start = try number(row["start_sample"]) / sampleRate
            end = try number(row["end_sample"]) / sampleRate
        } else if let stamps = row["timestamps"] as? [String: String],
            let from = stamps["from"], let to = stamps["to"]
        {
            start = try clock(from)
            end = try clock(to)
        } else {
            start = try number(row["start"] ?? row["start_time"])
            end = try number(row["end"] ?? row["end_time"])
        }
        return Cue(
            start: start, end: end, text: text,
            speaker: row["speaker_id"] as? String ?? row["speaker"] as? String)
    }
}
