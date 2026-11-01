// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The library's button, at the trailing edge of the library's top as the
/// system places its own, which it replaces on macOS 26 so as to take the
/// toolbar's smaller size with every other item (`ToolbarItemSize`). It
/// leaves its glass out over the library, which is glass already, and has it
/// on the bar while the library is hidden, as the system's does.
struct LibraryToggle: ViewModifier {
    @Binding var isShown: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem { button.modifier(ToolbarItemSize()) }
                        .sharedBackgroundVisibility(isShown ? .hidden : .automatic)
                }
        } else {
            content
        }
    }

    private var button: some View {
        Button {
            withAnimation { isShown.toggle() }
        } label: {
            Label("Library", systemImage: "sidebar.leading")
        }
        .help(isShown ? "Hide the library" : "Show the library")
    }
}

/// The inspector's button, at the trailing edge of the toolbar above it, the
/// mirror of the library's. On macOS 26 it leaves its glass out over the
/// inspector, which is glass already, and has it on the bar while the
/// inspector is hidden, as the library's. Branched here rather than inside
/// the toolbar, where an availability check needs macOS 14.5.
struct InspectorToggle: ViewModifier {
    @Binding var isShown: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem { button.modifier(ToolbarItemSize()) }
                    .sharedBackgroundVisibility(isShown ? .hidden : .automatic)
            }
        } else {
            content.toolbar {
                Spacer()
                button
            }
        }
    }

    private var button: some View {
        Button {
            isShown.toggle()
        } label: {
            Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help(isShown ? "Hide the inspector" : "Show the inspector")
    }
}
