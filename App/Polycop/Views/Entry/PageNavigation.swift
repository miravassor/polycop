// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Taking the page to a paragraph the reader asked for, from Find or a flag,
/// which stops it following playback until they come back. A value rather
/// than functions of the page, so the toolbar can hold it and still be left
/// alone when only the text changes.
struct PageNavigation {
    @Binding var activeParagraph: Int?
    @Binding var jump: Int?
    @Binding var isFollowSuspended: Bool
    let following: Following

    /// Stops following while the reader looks elsewhere, and offers the way back.
    func suspendFollowing() {
        guard following != .off, !isFollowSuspended else { return }
        isFollowSuspended = true
    }

    /// Brings a paragraph into view and makes it the active one.
    func show(_ paragraph: Int) {
        suspendFollowing()
        activeParagraph = paragraph
        jump = paragraph
    }
}
