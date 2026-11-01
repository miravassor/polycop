// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// The shapes the app repeats beyond the system's own: what floats at the foot
// of a page, a page's main action, notices, and the edge of a text editor,
// with a control's corners.

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

/// A capsule as tall as the player, for a page's actions: in the accent colour
/// when it is the main one, glass on macOS 26 as the player, the system's
/// material before.
struct ActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isProminent = true
    let action: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                if isProminent {
                    Button(title, systemImage: systemImage, action: action)
                        .buttonStyle(.glassProminent)
                } else {
                    Button(title, systemImage: systemImage, action: action)
                        .buttonStyle(.glass)
                }
            } else {
                if isProminent {
                    Button(title, systemImage: systemImage, action: action)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(title, systemImage: systemImage, action: action)
                        .buttonStyle(.bordered)
                }
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.extraLarge)
    }
}
