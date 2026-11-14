// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Actions shared by the sidebar's context menus.
struct LibraryMenu: View {
    let model: AppModel
    let newFolder: () -> Void

    var body: some View {
        @Bindable var layout = model.layout
        Button("New Folder…", action: newFolder)
            .disabled(model.foldersAreDamaged)
        Menu("Sort By") {
            Picker("Sort By", selection: $layout.sort) {
                Text("Date Added (Newest First)").tag(LibrarySort.newestFirst)
                Text("Date Added (Oldest First)").tag(LibrarySort.oldestFirst)
                Text("Name").tag(LibrarySort.name)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

#Preview {
    // An empty library and glossaries of its own, never the user's.
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    LibraryMenu(
        model: AppModel(
            history: folder.appending(path: "History"),
            glossaries: folder.appending(path: "Glossaries")),
        newFolder: {})
}
