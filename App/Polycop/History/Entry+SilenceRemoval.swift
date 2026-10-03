// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension Entry {
    /// Recording time outside the stretches the detector kept: total duration
    /// minus kept time, overlaps counted once and clipped to the recording
    /// length. Not exactly speech lost, since the kept stretches include some
    /// silence too.
    var leftOut: TimeInterval? {
        guard let speech, let duration else { return nil }
        var kept = 0.0
        var reached = 0.0
        for stretch in speech.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = max(stretch.lowerBound, reached)
            let end = min(stretch.upperBound, duration)
            if end > start {
                kept += end - start
                reached = end
            }
        }
        return max(0, duration - kept)
    }

    /// The stretches kept once `stretch` was transcribed again with silence
    /// removal: what was kept before outside it, the whole recording if
    /// nothing was removed, and inside it only what the detector kept.
    static func speech(
        _ speech: [ClosedRange<TimeInterval>]?, duration: TimeInterval,
        replacing stretch: ClosedRange<TimeInterval>, with kept: [ClosedRange<TimeInterval>]
    ) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        for range in speech ?? [0...duration] {
            if range.lowerBound < stretch.lowerBound {
                result.append(range.lowerBound...min(range.upperBound, stretch.lowerBound))
            }
            if range.upperBound > stretch.upperBound {
                result.append(max(range.lowerBound, stretch.upperBound)...range.upperBound)
            }
        }
        for range in kept where range.overlaps(stretch) {
            result.append(range.clamped(to: stretch))
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }
}
