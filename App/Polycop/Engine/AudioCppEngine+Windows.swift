// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where long audio is cut into windows.
nonisolated extension AudioCppEngine {
    /// Where a boundary is looked for around each nominal cut, and the span
    /// whose energy is compared. Values from the official Qwen3-ASR toolkit
    /// (`split_audio_into_chunks`), which cuts long audio at its quietest
    /// point rather than in the middle of a word, as mlx-qwen3-asr and
    /// antirez's qwen-asr also do.
    static let boundarySearch: TimeInterval = 5
    static let energyWindow: TimeInterval = 0.1

    /// The windows from `first` to the end, in samples, with no gap and no
    /// overlap, each ending at its nominal length or at the quietest point
    /// near it. A transcription that resumes starts where the last window it
    /// kept ended.
    static func windows(
        in samples: [Float], from first: Int, lasting seconds: TimeInterval, atSilence: Bool
    ) -> [Range<Int>] {
        guard seconds.isFinite, seconds > 0 else { return [] }
        let rate = Double(AudioDecoder.sampleRate)
        let length = max(1, Int(min(seconds, AudioDecoder.longestRecording) * rate))
        let expand = Int(boundarySearch * rate)
        let span = max(4, Int(energyWindow * rate))
        var windows: [Range<Int>] = []
        var start = max(0, first)
        while samples.count - start > length {
            let cut = start + length
            let left = max(start, cut - expand)
            let right = min(samples.count, cut + expand)
            let boundary =
                !atSilence || right - left <= span
                ? cut : quietest(in: samples, left..<right, span: span)
            let end = min(samples.count, max(boundary, start + 1))
            windows.append(start..<end)
            start = end
        }
        if start < samples.count { windows.append(start..<samples.count) }
        return windows
    }

    /// The quietest sample of the quietest span in `range`, spans compared by
    /// the sum of their absolute values, as the official toolkit does.
    private static func quietest(in samples: [Float], _ range: Range<Int>, span: Int) -> Int {
        var sum: Float = 0
        for index in range.lowerBound..<(range.lowerBound + span) { sum += abs(samples[index]) }
        var best = sum
        var bestStart = range.lowerBound
        for start in (range.lowerBound + 1)...(range.upperBound - span) {
            sum += abs(samples[start + span - 1]) - abs(samples[start - 1])
            if sum < best {
                best = sum
                bestStart = start
            }
        }
        let quiet = (bestStart..<(bestStart + span)).min { abs(samples[$0]) < abs(samples[$1]) }
        return quiet ?? bestStart
    }
}
