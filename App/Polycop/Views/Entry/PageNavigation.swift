// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Taking the page to a paragraph the reader asked for, from Find or a flag,
/// which stops it following playback until they come back. A dynamic property
/// so that SwiftUI compares its bindings, which in a plain value would count
/// as changed at each update and redraw the toolbar's Review menu holding it.
struct PageNavigation: DynamicProperty {
    @Binding var activeParagraph: Int?
    @Binding var jump: Int?
    @Binding var isFollowSuspended: Bool
    let following: Following
    let player: Player

    /// Stops following while the reader looks elsewhere, and offers the way
    /// back. With nothing open there is no playback to come back to, so a
    /// recording opened later is followed from the start.
    func suspendFollowing() {
        guard following != .off, player.isOpen, !isFollowSuspended else { return }
        isFollowSuspended = true
    }

    /// Brings a paragraph into view and makes it the active one.
    func show(_ paragraph: Int) {
        suspendFollowing()
        activeParagraph = paragraph
        jump = paragraph
    }
}
