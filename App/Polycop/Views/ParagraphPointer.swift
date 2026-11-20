// SPDX-License-Identifier: GPL-3.0-or-later

import Observation

/// The paragraph the pointer is on, by its time in the text or by its stretch
/// of the player's timeline, so that each shows it for the other. A page owns
/// one and hands it down; only what draws the paragraph reads it, so pointing
/// along the timeline redraws a row's background and not the page.
@Observable
final class ParagraphPointer {
    private(set) var paragraph: Int?

    /// Told at every move of the pointer: observers hear of a change only.
    func point(at paragraph: Int?) {
        if self.paragraph != paragraph { self.paragraph = paragraph }
    }
}
