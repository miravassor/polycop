// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension TranscriptImport {
    static func json(_ data: Data) throws -> Parsed {
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
