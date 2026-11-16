// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
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

extension FolderColor {
    var tint: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    /// A non-template symbol image that keeps its Finder colour inside AppKit
    /// menus, where SwiftUI strips `.foregroundStyle` and renders template
    /// symbols monochrome.
    func menuSymbol(_ systemName: String) -> Image {
        guard
            let image = NSImage(
                systemSymbolName: systemName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(paletteColors: [nsColor]))
        else {
            return Image(systemName: systemName)
        }
        return Image(nsImage: image)
    }
}

/// Trailing icons summarizing flairs on a transcript or collapsed folder row.
struct FlairIcons: View {
    let flairs: [TranscriptFlair]
    var hidesAccessibility = false

    var body: some View {
        HStack(spacing: Spacing.icon) {
            ForEach(flairs, id: \.self) { flair in
                Image(systemName: flair.symbol)
                    .font(.caption)
                    .foregroundStyle(flair.color.tint)
                    .accessibilityLabel(flair.displayTitle)
                    .accessibilityHidden(hidesAccessibility)
            }
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

    /// What is happening to a transcript, above its text, or the way back to
    /// playback above the player, on the surface of the player.
    func statusCapsule() -> some View {
        font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .modifier(FloatingSurface(shape: RoundedRectangle(cornerRadius: 22)))
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

    /// The highlight of a sidebar destination that accepts dropped items.
    func dropTargetHighlight(_ isTargeted: Bool) -> some View {
        padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isTargeted ? Color.accentColor.opacity(0.25) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    /// A selectable action row above the sidebar list, matching the corners and
    /// inset of a sidebar row.
    func sidebarRowSelection(_ isSelected: Bool) -> some View {
        modifier(SidebarRowSelection(isSelected: isSelected))
    }

    /// The field above the sidebar list that filters the library.
    func sidebarSearchField() -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct SidebarRowSelection: ViewModifier {
    let isSelected: Bool
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected && appearsActive ? Color.white : Color.primary)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(appearsActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                }
            }
            .contentShape(Rectangle())
    }
}

/// The arrow at the trailing edge of a section header that folds, pointing
/// down while open.
struct FoldChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }
}

/// The surface of what floats at the foot of a page, the player or Start:
/// glass on macOS 26, blurring what scrolls under it; the system's material
/// before.
struct FloatingSurface<Outline: InsettableShape>: ViewModifier {
    let shape: Outline

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // Glass placed in it would turn it dark in a light window while
            // it floats over the text; in a container the glass shapes render
            // together.
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
