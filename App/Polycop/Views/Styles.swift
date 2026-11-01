// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// The shapes the app repeats: cards have corners of 10 and 16 points of
// padding, the controls and rows inside them corners of 6.

extension View {
    /// Controls floating over the foot of a scrolling view: on macOS 26 the
    /// content scrolls under them with the system's soft edge, as Music's list
    /// under its player; before, under them as they are.
    @ViewBuilder func floatingBar(@ViewBuilder _ bar: () -> some View) -> some View {
        let bar = bar()
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom) { bar }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar }
        }
    }

    /// A card: a section of a page, or the player. A tint colours its fill
    /// alone, as each engine's card does in the model list.
    func panel(isHighlighted: Bool = false, tint: Color? = nil)
        -> some View
    {
        padding(.horizontal, 16)
            .padding(.vertical, 16)
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

/// The surface of what floats at the foot of a page, the player or Start:
/// glass on macOS 26, as Music's player, blurring what scrolls under it; the
/// system's material before. A capsule on one line, rounder corners on two.
struct FloatingSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
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
