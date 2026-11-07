// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension Entry {
    /// What the notices above a transcript report. Each reads the whole
    /// transcript, and typing changes none of them, so a page works them out
    /// once per change of the segments rather than at each key.
    struct Findings: Equatable {
        let repetitionWarning: String?
        let repeats: [ClosedRange<Int>]
        let hiddenCredits: [Segment]
        let shortenedLoops: [Segment]

        /// Whether a warning offers to rebuild the text.
        var offersRebuild: Bool {
            !repeats.isEmpty || !hiddenCredits.isEmpty || !shortenedLoops.isEmpty
        }
    }

    var findings: Findings {
        let cleaned = cleaned
        return Findings(
            repetitionWarning: Degeneration.check(showsCredits ? decoded : cleaned.speech)
                .map(Degeneration.warning),
            repeats: repeats,
            hiddenCredits: showsCredits ? [] : cleaned.credits,
            shortenedLoops: showsCredits ? [] : cleaned.looped)
    }

    /// Stretches where one phrase repeats in a row, which can be transcribed
    /// again. Read from the raw segments, which is what a repair replaces.
    var repeats: [ClosedRange<Int>] { Degeneration.repeats(in: decoded) }

    /// What can be said about the text. The names are stored: never rename them.
    /// `CaseIterable` for the test that holds them to that.
    enum Warning: String, CaseIterable {
        case glossary, repeats, resumed, gaps, leftOut, credits, loops
    }

    func isDismissed(_ warning: Warning) -> Bool {
        dismissedWarnings?.contains(warning.rawValue) == true
    }

    mutating func setDismissed(_ warning: Warning, _ isDismissed: Bool) {
        var names = dismissedWarnings ?? []
        if isDismissed {
            names.insert(warning.rawValue)
        } else {
            names.remove(warning.rawValue)
        }
        dismissedWarnings = names.isEmpty ? nil : names
    }
}
