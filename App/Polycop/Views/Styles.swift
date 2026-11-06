// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// The shapes the app repeats beyond the system's own: what floats at the foot
// of a page, a page's main action, notices, and the edge of a text editor,
// with a control's corners; and the spacing and text of each role.

/// The space each role takes. A small gap inside a row is the stack's own,
/// with no number.
enum Spacing {
    /// Between an icon and the text it belongs to.
    static let icon: CGFloat = 4
    /// Around a page.
    static let page: CGFloat = 28
    /// Around a sheet.
    static let sheet: CGFloat = 24
    /// Between the blocks of a page or a sheet.
    static let block: CGFloat = 16
}

extension Font {
    static let sheetTitle = Font.title2.weight(.semibold)
}

/// A state a notice tells, with one symbol and one colour wherever it shows.
enum NoticeState {
    /// Something to check; the work went on.
    case warning
    /// What was asked did not happen.
    case failure

    var symbol: String {
        switch self {
        case .warning: "exclamationmark.triangle"
        case .failure: "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .warning: .orange
        case .failure: .red
        }
    }
}

/// A warning or a failure: the state's symbol in its colour, the text in the
/// label colours.
struct Notice: View {
    private let title: Text
    private let state: NoticeState

    init(_ title: LocalizedStringKey, _ state: NoticeState) {
        self.title = Text(title)
        self.state = state
    }

    init(_ title: some StringProtocol, _ state: NoticeState) {
        self.title = Text(title)
        self.state = state
    }

    var body: some View {
        Label {
            title
        } icon: {
            Image(systemName: state.symbol)
        }
        .notice(state.tint)
    }
}

extension View {
    /// Controls floating over the foot of a scrolling view: on macOS 26 the
    /// content scrolls under them with the system's soft edge; before, under
    /// them as they are.
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

    /// What is happening to a transcript, above its text, on the surface of
    /// the player below it.
    func statusCapsule() -> some View {
        font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .modifier(FloatingSurface(cornerRadius: 22))
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
/// glass on macOS 26, blurring what scrolls under it; the system's material
/// before. A capsule on one line, rounder corners on two.
struct FloatingSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(macOS 26, *) {
            // Glass placed in it, as the player's timeline, would turn it
            // dark in a light window while it floats over the text; in a
            // container the glass shapes render together.
            GlassEffectContainer { content.glassEffect(.regular, in: shape) }
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

struct NoticeLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.icon) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
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

#Preview("Notices") {
    VStack(alignment: .leading, spacing: Spacing.block) {
        Notice("The glossary is longer than Whisper reads.", .warning)
        Notice("The recording could not be read.", .failure)
    }
    .font(.callout)
    .padding(Spacing.sheet)
}
