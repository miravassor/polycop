// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Writes a finished transcription to disk, as paragraphs of text in the
/// layout chosen for it and as SubRip captions for a player.
///
/// Captions keep the segment times the engine reported. Splitting a long
/// segment by counting words would assume an even speaking rate and place
/// words at times no measurement supports.
nonisolated enum Transcript {
    /// One paragraph of the text, opening `start` milliseconds into the recording.
    nonisolated struct Paragraph: Equatable, Codable, Sendable {
        let start: Int
        var text: String

        var time: String { Transcript.clock(start) }
        var seconds: TimeInterval { TimeInterval(start) / 1000 }
    }

    /// A paragraph running this long closes at the next segment regardless of
    /// punctuation. Paragraphs normally close on a pause or on a sentence end
    /// past the word count threshold, but some lecturers do neither; this
    /// ceiling bounds how long a single paragraph, and its single seek point,
    /// can get.
    static let longest: TimeInterval = 90

    /// Groups segments into paragraphs, applying the ceiling above. A
    /// paragraph closes after 1.5 s of silence, or once it holds 120 words and
    /// ends a sentence, and opens on the time of its first segment. Times are
    /// compared in whole milliseconds, so an exact 1.5 s silence always closes
    /// a paragraph.
    ///
    /// Where a model tells speakers apart, a new speaker opens a paragraph,
    /// which begins with a speaker label.
    static func paragraphs(_ segments: [Segment]) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var words: [Substring] = []
        var opening = 0
        var previousEnd = 0
        var speaker: String?

        func close() {
            paragraphs.append(Paragraph(start: opening, text: words.joined(separator: " ")))
            words = []
        }

        for segment in segments {
            let spoken = segment.text.split(whereSeparator: \.isWhitespace)
            guard !spoken.isEmpty else { continue }
            let start = milliseconds(segment.start)
            let overlong = Double(start - opening) >= longest * 1000
            let turns = segment.speaker != nil && segment.speaker != speaker
            let closes =
                start - previousEnd >= 1500 || (words.count >= 120 && endsSentence(words))
                || overlong || turns
            if !words.isEmpty && closes { close() }
            if words.isEmpty {
                opening = start
                speaker = segment.speaker
                if let label = label(of: segment.speaker) { words.append(Substring(label)) }
            }
            words += spoken
            previousEnd = milliseconds(segment.end)
        }
        if !words.isEmpty { close() }
        return paragraphs
    }

    /// "Speaker 2:" for MOSS's "S02".
    static func label(of speaker: String?) -> String? {
        guard let speaker, speaker.first == "S", let number = Int(speaker.dropFirst()) else {
            return nil
        }
        return String(localized: "Speaker \(number):")
    }

    /// The text file, with every paragraph opening on its timestamp.
    static func text(_ segments: [Segment]) -> String {
        text(paragraphs(segments))
    }

    static func text(_ paragraphs: [Paragraph]) -> String {
        paragraphs.map { "[\($0.time)] \($0.text)\n\n" }.joined()
    }

    /// How the text export lays out paragraphs. Stored with each transcript.
    nonisolated enum TextLayout: String, Codable, CaseIterable, Sendable {
        case timestamped
        case plain
        case markdown

        var suffix: String { self == .markdown ? "md" : "txt" }
    }

    static func text(_ paragraphs: [Paragraph], layout: TextLayout, title: String) -> String {
        switch layout {
        case .timestamped: text(paragraphs)
        case .plain: paragraphs.map { "\($0.text)\n\n" }.joined()
        case .markdown:
            "# \(markdownEscaped(title))\n\n"
                + paragraphs.map { "**\($0.time)** \(markdownEscaped($0.text))\n\n" }.joined()
        }
    }

    /// Markdown reads some of a lecture's characters as formatting: "2*3*4"
    /// as italics, a line opening on "#" or "1." as a heading or a list. Those
    /// are escaped, and only those, so the file still reads as plain text.
    static func markdownEscaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\`*_[]<>~|".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return
            escaped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map {
                $0.replacing(/^(\s*)([#+=-])/) { "\($0.1)\\\($0.2)" }
                    .replacing(/^(\s*\d+)([.)])/) { "\($0.1)\\\($0.2)" }
            }
            .joined(separator: "\n")
    }

    /// A segment with no text, which the engine can write, has no cue: a
    /// player would show an empty caption.
    static func subRip(_ segments: [Segment]) -> String {
        var lines: [String] = []
        let spoken = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for (index, segment) in spoken.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(subRipClock(segment.start)) --> \(subRipClock(segment.end))")
            lines.append(segment.text.trimmingCharacters(in: .whitespaces))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Writes the transcript where the user chose to put it. Every format
    /// shares the name the user typed, so a player pairs the subtitle with
    /// the right recording. The save panel asks before replacing the file it
    /// shows, and only that one: any other file of the export, the subtitle,
    /// or the text under its own suffix when the name typed had another,
    /// never replaces one already there.
    @discardableResult
    static func write(
        _ formats: [(suffix: String, contents: String)], as destination: URL
    ) throws -> [URL] {
        let folder = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        let files = formats.map { folder.appending(path: "\(stem).\($0.suffix)") }
        if let existing = files.first(where: {
            $0.lastPathComponent != destination.lastPathComponent
                && FileManager.default.fileExists(atPath: $0.path)
        }) {
            throw ExistingFile(file: existing)
        }
        return try write(formats, to: files)
    }

    /// A file of the export that the save panel did not ask about.
    struct ExistingFile: LocalizedError {
        let file: URL
        var errorDescription: String? {
            file.pathExtension == "srt"
                ? String(
                    localized:
                        "\(file.lastPathComponent) already exists. Choose another export name or turn off subtitles. No files were changed."
                )
                : String(
                    localized:
                        "\(file.lastPathComponent) already exists. Choose another export name. No files were changed."
                )
        }
    }

    /// The name the save panel opens with, based on the transcript's own
    /// name, which tells apart two transcripts of the same lecture. A
    /// transcript stopped before the end says so in its name, so it cannot
    /// pass for a whole lecture later.
    static func suggestedName(for transcript: String, partial: Bool) -> String {
        let name = (transcript as NSString).deletingPathExtension
        return partial ? String(localized: "\(name) (partial)") : name
    }

    /// Overwrites files saved earlier for the same result, but only when each
    /// still holds exactly what was written (checked by digest) and they
    /// match the formats one for one. Returns nil otherwise, so a file
    /// changed elsewhere is never overwritten.
    static func update(
        _ files: [URL], holding digests: [String],
        with formats: [(suffix: String, contents: String)]
    ) throws -> [URL]? {
        guard !files.isEmpty, files.count == formats.count, digests.count == files.count,
            zip(files, formats).allSatisfy({ $0.pathExtension == $1.suffix }),
            zip(files, digests).allSatisfy({ digest(ofFileAt: $0) == $1 })
        else { return nil }
        return try write(formats, to: files)
    }

    private static func write(
        _ formats: [(suffix: String, contents: String)], to files: [URL]
    ) throws -> [URL] {
        var written: [URL] = []
        for (file, format) in zip(files, formats) {
            do {
                try format.contents.write(to: file, atomically: true, encoding: .utf8)
                written.append(file)
            } catch {
                if written.isEmpty { throw error }
                throw PartialSave(written: written, failure: error)
            }
        }
        return written
    }

    /// A SHA-256 in hexadecimal, kept instead of the text a file held.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ text: String) -> String {
        digest(Data(text.utf8))
    }

    /// Digest of a file the app does not own, read in blocks since anything
    /// could be at that path now, possibly too large to hold in memory. Nil
    /// if the file is no longer there.
    static func digest(ofFileAt file: URL) -> String? {
        try? FileDigest.sha256(of: file)
    }

    /// A later format failed after earlier ones were written. What was written
    /// stays on disk, and the message names it.
    struct PartialSave: LocalizedError {
        let written: [URL]
        let failure: any Error

        var errorDescription: String? {
            let names = written.map(\.lastPathComponent).formatted(.list(type: .and))
            return String(
                localized:
                    "Saved \(names), but the next file could not be written: \(failure.localizedDescription)"
            )
        }
    }

    /// Rounds rather than truncates. The engine reports hundredths of a
    /// second, and 12.34 held as a Double is 12.3399999; truncating would
    /// give 12,339 instead of 12,340.
    private static func milliseconds(_ time: TimeInterval) -> Int {
        Int((time * 1000).rounded())
    }

    private static func endsSentence(_ words: [Substring]) -> Bool {
        guard let character = words.last?.last else { return false }
        return ".!?…".contains(character)
    }

    static func clock(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private static func subRipClock(_ time: TimeInterval) -> String {
        let total = milliseconds(time)
        return clock(total) + String(format: ",%03d", total % 1000)
    }
}
