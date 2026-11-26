// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import SwiftUI

/// Where the reader is focused and scrolled on a transcript page, kept on an
/// observable object so clicking between paragraphs or scrolling away from
/// playback updates only the text and the Playback menu without redrawing the
/// page's toolbar or inspector.
@Observable
final class PageNavigationState {
    var activeParagraph: Int? {
        didSet {
            let active = activeParagraph != nil
            if hasActiveParagraph != active { hasActiveParagraph = active }
        }
    }
    /// Whether any paragraph is active. Kept apart from `activeParagraph` so
    /// moving between paragraphs does not notify commands that ask only
    /// whether a paragraph can be replayed.
    private(set) var hasActiveParagraph = false
    var isFollowSuspended = false
    var jump: Int?
    var showAtTop: Int?
}

/// Taking the page to a paragraph the reader asked for, from Find or a flag,
/// which stops it following playback until they come back. Holds the page's
/// navigation state reference rather than bindings, so SwiftUI compares it as
/// equal across updates of the page and its tools.
struct PageNavigation {
    let state: PageNavigationState
    let following: Following
    let player: Player

    var activeParagraph: Int? { state.activeParagraph }

    /// Stops following while the reader looks elsewhere, and offers the way
    /// back, to where the recording stands, paused or not. With none open
    /// there is nowhere to come back to, so one opened later is followed from
    /// the start.
    func suspendFollowing() {
        guard following != .off, player.isOpen, !state.isFollowSuspended else { return }
        state.isFollowSuspended = true
    }

    /// Brings a paragraph into view and makes it the active one.
    func show(_ paragraph: Int) {
        suspendFollowing()
        state.activeParagraph = paragraph
        state.jump = paragraph
    }
}
