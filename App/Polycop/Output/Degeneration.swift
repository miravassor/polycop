// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whisper can fall into repeating one phrase for the rest of a recording.
///
/// Silence removal is off by default, which keeps that risk in exchange for a
/// warning on every result. Counting only a run in a row would miss a phrase
/// that repeats through nearly the whole transcript, so a share of the total
/// is checked as well. A repetition is never removed; the user decides.
nonisolated enum Degeneration {
    /// A phrase this many times in a row is no longer ordinary speech. It is also
    /// the least a phrase must occur before its share counts, so a short result
    /// of one to three distinct segments is never called a repetition.
    static let longestOrdinaryRun = 10
    /// Above this share of the transcript, one phrase has taken over.
    static let largestOrdinaryShare = 0.3

    /// One phrase, with its own longest run in a row and its own share.
    struct Finding: Equatable {
        let phrase: String
        let run: Int
        let share: Double
    }

    static func check(_ segments: [Segment]) -> Finding? {
        let texts = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
        guard !texts.isEmpty else { return nil }

        var counts: [String: Int] = [:]
        var runs: [String: Int] = [:]
        var current = 0
        var previous: String?
        for text in texts {
            current = text == previous ? current + 1 : 1
            previous = text
            counts[text, default: 0] += 1
            runs[text] = max(runs[text, default: 0], current)
        }

        // Run and share are always those of the phrase reported.
        func finding(_ phrase: String) -> Finding {
            Finding(
                phrase: phrase,
                run: runs[phrase, default: 0],
                share: Double(counts[phrase, default: 0]) / Double(texts.count))
        }

        if let longest = runs.max(by: { $0.value < $1.value }),
            longest.value >= longestOrdinaryRun
        {
            return finding(longest.key)
        }
        if let frequent = counts.max(by: { $0.value < $1.value }),
            frequent.value >= longestOrdinaryRun,
            Double(frequent.value) / Double(texts.count) > largestOrdinaryShare
        {
            return finding(frequent.key)
        }
        return nil
    }

    /// Where one phrase repeats in a row, as ranges of segment indices; these
    /// are the stretches that can be retranscribed. A phrase that is merely
    /// frequent across the whole transcript has no single place to repair.
    static func repeats(in segments: [Segment]) -> [ClosedRange<Int>] {
        var found: [ClosedRange<Int>] = []
        var first = 0
        while first < segments.count {
            let text = segments[first].text.trimmingCharacters(in: .whitespaces)
            var last = first
            while last + 1 < segments.count,
                segments[last + 1].text.trimmingCharacters(in: .whitespaces) == text
            {
                last += 1
            }
            if last - first + 1 >= longestOrdinaryRun { found.append(first...last) }
            first = last + 1
        }
        return found
    }

    /// A character or short pattern repeated more than this many times in a
    /// row is treated as a loop, not speech. Matches the official Qwen3-ASR
    /// toolkit's rule (`detect_and_fix_repetitions`, threshold 20, patterns of
    /// 1 to 20 characters), applied to every transcript it returns.
    static let loopThreshold = 20
    static let longestLoopPattern = 20

    /// The text with each loop reduced to one occurrence of what repeats, as
    /// the official toolkit does. Over silence, Qwen can repeat one word
    /// hundreds of times in a single window.
    static func shortened(_ text: String) -> String {
        String(collapsePatterns(collapseCharacters(Array(text))))
    }

    /// A run of one character longer than the threshold keeps one.
    private static func collapseCharacters(_ text: [Character]) -> [Character] {
        var result: [Character] = []
        var index = 0
        while index < text.count {
            var count = 1
            while index + count < text.count, text[index + count] == text[index] { count += 1 }
            result += count > loopThreshold ? [text[index]] : text[index..<(index + count)]
            index += count
        }
        return result
    }

    /// The first pattern of up to 20 characters repeated more than the
    /// threshold keeps one occurrence, then the rest is read the same way.
    private static func collapsePatterns(_ text: [Character]) -> [Character] {
        let shortest = loopThreshold * 2
        guard text.count >= shortest else { return text }
        var result: [Character] = []
        var index = 0
        while index <= text.count - shortest {
            var collapsed = false
            for length in 1...longestLoopPattern where index + length * loopThreshold <= text.count
            {
                let pattern = text[index..<(index + length)]
                let repeated = (1..<loopThreshold).allSatisfy {
                    text[(index + $0 * length)..<(index + ($0 + 1) * length)] == pattern
                }
                guard repeated else { continue }
                var end = index + loopThreshold * length
                while end + length <= text.count, text[end..<(end + length)] == pattern {
                    end += length
                }
                result += pattern
                index = end
                collapsed = true
                break
            }
            if !collapsed {
                result.append(text[index])
                index += 1
            }
        }
        return result + text[index...]
    }

    /// The segments with their loops reduced, and the originals of those that
    /// changed. Like a credit line, the original is kept and can be put back.
    static func shortenLoops(_ segments: [Segment]) -> (speech: [Segment], looped: [Segment]) {
        var speech: [Segment] = []
        var looped: [Segment] = []
        for segment in segments {
            let text = shortened(segment.text)
            if text == segment.text {
                speech.append(segment)
            } else {
                looped.append(segment)
                speech.append(segment.replacing(text: text))
            }
        }
        return (speech, looped)
    }

    /// Says where the first shortened passage is, so it can be listened to.
    static func loopNotice(_ looped: [Segment]) -> String? {
        guard let first = looped.first else { return nil }
        let time = Transcript.clock(Int((first.start * 1000).rounded()))
        if looped.count == 1 {
            return String(
                localized:
                    "Shortened the passage at \(time), where the model repeated the same words over and over, as it can over silence."
            )
        }
        return String(
            localized:
                "Shortened \(looped.count) passages where the model repeated the same words over and over, as it can over silence. The first is at \(time)."
        )
    }

    /// Describes what was observed, without guessing at its cause.
    static func warning(_ finding: Finding) -> String {
        let percent = Int((finding.share * 100).rounded())
        if finding.run >= longestOrdinaryRun {
            return String(
                localized:
                    "The same phrase appears \(finding.run) times in a row, \(percent) per cent of this transcript. Nothing has been removed: read the result before relying on it."
            )
        }
        return String(
            localized:
                "One phrase makes up \(percent) per cent of this transcript. Nothing has been removed: read the result before relying on it."
        )
    }
}
