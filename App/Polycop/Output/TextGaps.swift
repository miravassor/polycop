// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Stretches of a recording where the engine wrote nothing for a minute or
/// more: a long pause, or speech it missed. A streamed engine can stop
/// writing for minutes, and a window cut by its token limit loses its end,
/// so the transcript says where to listen.
nonisolated enum TextGaps {
    static let shortest: TimeInterval = 60

    /// `segments` in the order they start. The end of the recording counts
    /// when its length is known.
    static func stretches(
        in segments: [Segment], lasting duration: TimeInterval?
    ) -> [ClosedRange<TimeInterval>] {
        var stretches: [ClosedRange<TimeInterval>] = []
        var reached: TimeInterval = 0
        for segment in segments {
            if segment.start - reached >= shortest { stretches.append(reached...segment.start) }
            reached = max(reached, segment.end)
        }
        if let duration, duration - reached >= shortest { stretches.append(reached...duration) }
        return stretches
    }
}
