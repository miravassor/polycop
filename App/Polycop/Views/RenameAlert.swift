// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Asks for a transcript's new name in the library.
struct RenameAlert: ViewModifier {
    @Binding var renamed: Entry.ID?
    @Binding var name: String
    let model: AppModel

    func body(content: Content) -> some View {
        content.alert(
            "Rename transcript",
            isPresented: Binding(get: { renamed != nil }, set: { if !$0 { renamed = nil } })
        ) {
            TextField("Transcript name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renamed { model.rename(renamed, to: name) }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Only the name in the library changes. The recording keeps its own.")
        }
    }
}
