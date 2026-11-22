// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Parses an externally authored transcript (SRT, VTT, timestamped TXT or Word
/// document, or a Whisper/audio.cpp JSON export) into cues for `Entry`.
nonisolated enum TranscriptImport {
    static let maximumBytes = 5 << 20
    /// Stored in `Entry.modelFile` for imported transcripts; never change its value.
    static let importedModel = "imported"

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
                        "Choose a timestamped TXT or Word document, an SRT or VTT file, or a supported Whisper/audio.cpp JSON file. Plain text without timestamps is not supported."
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
                recording: recording, modelFile: TranscriptImport.importedModel, glossary: nil,
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
        switch suffix.lowercased() {
        case "json":
            parsed = try json(data)
        case "docx":
            parsed = try timestamped(wordText(data))
        case "srt", "vtt":
            parsed = try subtitles(decodeText(data))
        case "txt":
            parsed = try plainText(decodeText(data))
        default:
            throw Failure.unsupported
        }
        try validate(parsed.cues)
        return parsed
    }

    static func validate(_ cues: [Cue]) throws {
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

    static func clock(_ string: String) throws -> Double {
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

    private static func decodeText(_ data: Data) throws -> String {
        // Older subtitle tools save French in Windows Latin.
        guard let decoded = TextFile.decode(data), !decoded.contains("\u{0}") else {
            throw Failure.unsupported
        }
        return decoded
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
}
