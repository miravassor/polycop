// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

@MainActor
@Test func theWindowStartsWithEverythingShown() {
    let layout = WindowLayout(defaults: MemoryDefaults())
    #expect(layout.showsLibrary)
    #expect(layout.showsInspector)
    #expect(layout.libraryWidth == Double(ContentView.idealLibraryWidth))
    #expect(layout.inspectorWidth == Double(EntryView.idealInspectorWidth))
    #expect(layout.openFolders.isEmpty)
}

/// The keys are written out: changing one would lose what readers chose. The
/// two widths were stored under these keys before this type existed.
@MainActor
@Test func theWindowReadsWhatWasStored() {
    let defaults = MemoryDefaults()
    let folder = UUID()
    defaults.set(false, forKey: "showsLibrary")
    defaults.set(false, forKey: "showsInspector")
    defaults.set(250.0, forKey: "libraryWidth")
    defaults.set(450.0, forKey: "inspectorWidth")
    defaults.set([folder.uuidString, "not one"], forKey: "openFolders")
    let layout = WindowLayout(defaults: defaults)
    #expect(!layout.showsLibrary)
    #expect(!layout.showsInspector)
    #expect(layout.libraryWidth == 250)
    #expect(layout.inspectorWidth == 450)
    #expect(layout.openFolders == [folder])
}

@MainActor
@Test func theWindowIsRememberedForTheNextLaunch() {
    let defaults = MemoryDefaults()
    let layout = WindowLayout(defaults: defaults)
    let folder = UUID()
    layout.showsLibrary = false
    layout.showsInspector = false
    layout.libraryWidth = 250
    layout.inspectorWidth = 450
    layout.openFolders = [folder]
    let next = WindowLayout(defaults: defaults)
    #expect(!next.showsLibrary)
    #expect(!next.showsInspector)
    #expect(next.libraryWidth == 250)
    #expect(next.inspectorWidth == 450)
    #expect(next.openFolders == [folder])
}
