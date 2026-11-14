// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Actions shared by the sidebar's context menus.
struct LibraryMenu: View {
    let model: AppModel
    let newFolder: () -> Void

    var body: some View {
        Button("New Folder…", action: newFolder)
            .disabled(model.foldersAreDamaged)
        SortByMenu(layout: model.layout)
    }
}

/// Chooses the sidebar's transcript order from any library context menu.
struct SortByMenu: View {
    @Bindable var layout: WindowLayout

    var body: some View {
        Menu("Sort By") {
            Picker("Sort By", selection: $layout.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { order in
                    Text(Self.title(of: order)).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    static func title(of sort: LibrarySort) -> String {
        switch sort {
        case .newestFirst: String(localized: "Date Added (Newest First)")
        case .oldestFirst: String(localized: "Date Added (Oldest First)")
        case .name: String(localized: "Name")
        }
    }
}

#Preview {
    SortByMenu(layout: WindowLayout(defaults: MemoryDefaults()))
}
