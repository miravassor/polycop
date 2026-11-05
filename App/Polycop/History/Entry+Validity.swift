// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension Entry {
    /// Mends what a record can hold out of place without losing anything the
    /// user wrote. Before 0.4, MOSS could write a turn before the one it
    /// follows where voices overlap, and the record was refused: its segments
    /// and paragraphs are sorted by start, each text staying with its time.
    /// A playback position out of bounds is forgotten; the page already
    /// ignores a reading place it does not have.
    mutating func repair() {
        let order = paragraphs.indices.sorted { paragraphs[$0].start < paragraphs[$1].start }
        if order != Array(paragraphs.indices) {
            decoded.sort { $0.start < $1.start }
            paragraphs = order.map { paragraphs[$0] }
            originalParagraphs = originalParagraphs?.sorted { $0.start < $1.start }
            readingParagraph = readingParagraph.flatMap { order.firstIndex(of: $0) }
        }
        let ceiling = AudioDecoder.longestRecording + 60
        if let position = playbackPosition, !(0...ceiling).contains(position) {
            playbackPosition = nil
        }
    }

    /// Whether every numeric field is finite and within plausible bounds;
    /// used to reject a record too corrupted to display safely.
    var hasValidHistory: Bool {
        let ceiling = AudioDecoder.longestRecording + 60
        func time(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= ceiling }
        func paragraphsAreValid(_ values: [Transcript.Paragraph]) -> Bool {
            values.allSatisfy { $0.start >= 0 && Double($0.start) <= ceiling * 1000 }
                && zip(values, values.dropFirst()).allSatisfy { $0.start <= $1.start }
        }
        return recording.isFileURL && saved.allSatisfy(\.isFileURL)
            // A segment with end before start still renders safely; older
            // whisper.cpp output can contain one.
            && decoded.allSatisfy { time($0.start) && time($0.end) }
            && paragraphsAreValid(paragraphs)
            && paragraphsAreValid(originalParagraphs ?? [])
            && (duration.map(time) ?? true)
            && (resumedAt ?? []).allSatisfy(time)
            && (speech ?? []).allSatisfy { time($0.lowerBound) && time($0.upperBound) }
            && (transcribedIn.map { $0.isFinite && $0 >= 0 && $0 <= 365 * 24 * 60 * 60 } ?? true)
    }
}
