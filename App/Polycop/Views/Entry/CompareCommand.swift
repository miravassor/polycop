// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

extension FocusedValues {
    /// Whether the open transcript shows its original beside the text.
    @Entry var comparesOriginal: Binding<Bool>?
}

/// Compare in the View menu, as the toolbar's button: every toolbar item also
/// has a menu command, which works with the toolbar hidden.
struct CompareCommand: Commands {
    @FocusedValue(\.comparesOriginal) private var comparesOriginal

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Compare with Original", isOn: comparesOriginal ?? .constant(false))
                .disabled(comparesOriginal == nil)
        }
    }
}
