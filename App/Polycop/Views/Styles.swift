// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// The shapes the app repeats: blocks with padding have corners of 10, the
// controls and rows inside them corners of 6.

extension View {
    /// A card: a section of a page, or the player.
    func panel(padding: CGFloat = 20, isHighlighted: Bool = false) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHighlighted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isHighlighted ? Color.accentColor : Color.primary.opacity(0.1))
                    .allowsHitTesting(false)
            }
    }

    /// An icon button or menu of a page header, all of one size.
    func iconControl() -> some View {
        frame(width: 32, height: 28)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
