// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// The shapes the app repeats: cards have corners of 10 and 16 points of
// padding, the controls and rows inside them corners of 6.

extension View {
    /// A card: a section of a page, or the player. A tint colours its fill
    /// alone, as each engine's card does in the model list.
    func panel(isHighlighted: Bool = false, tint: Color? = nil) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHighlighted
                    ? Color.accentColor.opacity(0.08)
                    : tint?.opacity(0.08) ?? Color.primary.opacity(0.03),
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
        frame(width: 32, height: 28).controlFill()
    }

    /// The fill of a control drawn by hand. The header's icon controls have
    /// it, and the player's speed menu, as tall as the player's buttons.
    func controlFill() -> some View {
        background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    /// A notice: its icon carries the colour of what it says, its text keeps
    /// the label colour. Orange or red text on a light window falls below a
    /// readable contrast.
    func notice(_ tint: Color) -> some View {
        labelStyle(NoticeLabelStyle(tint: tint))
    }

    /// The edge of a text editor, with the corners of a control.
    func editorBorder() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator)
                    .allowsHitTesting(false)
            }
    }
}

struct NoticeLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(tint)
        }
        .labelStyle(.titleAndIcon)
    }
}
