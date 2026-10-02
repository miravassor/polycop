// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension Entry {
    /// Where a finished transcript has no text for a minute or more. Not with
    /// Skip silences, whose notice already says how much it left out.
    var textGaps: [ClosedRange<TimeInterval>] {
        guard state == .finished, !skipsSilence else { return [] }
        return TextGaps.stretches(in: decoded, lasting: duration)
    }
}
