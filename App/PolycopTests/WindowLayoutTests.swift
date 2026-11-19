// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
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
    #expect(layout.sort == .newestFirst)
}

/// The keys are written out: changing one would lose what readers chose. The
/// two widths were stored under these keys before this type existed.
@MainActor
@Test func theWindowReadsWhatWasStored() {
    let defaults = MemoryDefaults()
    let folder = UUID()
    let inset = Double(ContentView.libraryInset)
    defaults.set(false, forKey: "showsLibrary")
    defaults.set(false, forKey: "showsInspector")
    defaults.set(420.0, forKey: "libraryWidth")
    defaults.set(420.0 + inset, forKey: "inspectorWidth")
    defaults.set([folder.uuidString, "not one"], forKey: "openFolders")
    defaults.set("name", forKey: "librarySort")
    let layout = WindowLayout(defaults: defaults)
    #expect(!layout.showsLibrary)
    #expect(!layout.showsInspector)
    #expect(layout.libraryWidth == 420)
    #expect(layout.inspectorWidth == 420 + inset)
    #expect(layout.openFolders == [folder])
    #expect(layout.sort == .name)

    defaults.set(250.0, forKey: "libraryWidth")
    defaults.set(450.0, forKey: "inspectorWidth")
    defaults.set("unknown", forKey: "librarySort")
    let fallback = WindowLayout(defaults: defaults)
    #expect(fallback.libraryWidth == Double(ContentView.idealLibraryWidth))
    #expect(fallback.inspectorWidth == Double(EntryView.idealInspectorWidth))
    #expect(fallback.sort == .newestFirst)
}

@MainActor
@Test func theWindowIsRememberedForTheNextLaunch() {
    let defaults = MemoryDefaults()
    let layout = WindowLayout(defaults: defaults)
    let folder = UUID()
    let inset = Double(ContentView.libraryInset)
    layout.showsLibrary = false
    layout.showsInspector = false
    layout.libraryWidth = 420
    #expect(layout.inspectorWidth == 420 + inset)
    layout.inspectorWidth = 450
    #expect(layout.libraryWidth == 450 - inset)
    layout.openFolders = [folder]
    layout.sort = .oldestFirst
    let next = WindowLayout(defaults: defaults)
    #expect(!next.showsLibrary)
    #expect(!next.showsInspector)
    #expect(next.libraryWidth == 450 - inset)
    #expect(next.inspectorWidth == 450)
    #expect(next.openFolders == [folder])
    #expect(next.sort == .oldestFirst)
}

@MainActor
@Test func narrowWindowsFoldInspectorThenLibraryWithoutChangingStoredChoices() {
    let defaults = MemoryDefaults()
    let layout = WindowLayout(defaults: defaults)
    #expect(layout.showsLibrary)
    #expect(layout.showsInspector)

    layout.windowWidth = 1440
    #expect(layout.isLibraryShown)
    #expect(layout.isInspectorShown)

    layout.windowWidth = 1000
    #expect(layout.isLibraryShown)
    #expect(!layout.isInspectorShown)
    layout.isInspectorShown = true
    #expect(layout.isInspectorShown)
    #expect(!layout.isLibraryShown)
    #expect(layout.showsLibrary)
    #expect(WindowLayout(defaults: defaults).showsLibrary)
    layout.isLibraryShown = true
    #expect(layout.isLibraryShown)
    #expect(!layout.isInspectorShown)

    layout.windowWidth = 735
    #expect(!layout.isLibraryShown)
    #expect(!layout.isInspectorShown)

    layout.windowWidth = 506
    #expect(!layout.isLibraryShown)
    #expect(!layout.isInspectorShown)

    #expect(layout.showsLibrary)
    #expect(layout.showsInspector)
    #expect(WindowLayout(defaults: defaults).showsLibrary)
    #expect(WindowLayout(defaults: defaults).showsInspector)

    layout.windowWidth = 1440
    #expect(layout.isLibraryShown)
    #expect(layout.isInspectorShown)

    layout.libraryWidth = 504.3
    let synced = WindowLayout(defaults: defaults)
    #expect(synced.libraryWidth == 504.3)
    #expect(synced.inspectorWidth == 504.3 + Double(ContentView.libraryInset))
}

/// SwiftUI writes a column's fold back through its binding once AppKit has
/// folded it, as if the reader had hidden it.
@MainActor
@Test func aFoldWrittenBackBySwiftUIComesBackWhenTheWindowWidens() {
    let defaults = MemoryDefaults()
    let layout = WindowLayout(defaults: defaults)

    layout.windowWidth = 1000
    layout.isInspectorShown = false
    layout.windowWidth = 1440
    #expect(layout.isInspectorShown)

    layout.windowWidth = 1000
    layout.isInspectorShown = true
    layout.isLibraryShown = false
    #expect(layout.isInspectorShown)
    layout.windowWidth = 1440
    #expect(layout.isLibraryShown)

    #expect(WindowLayout(defaults: defaults).showsLibrary)
    #expect(WindowLayout(defaults: defaults).showsInspector)
}

@MainActor
@Test func columnWidthCeilingsReservePageMinimumWidthWithoutOverwritingStoredWidth() {
    let layout = WindowLayout(defaults: MemoryDefaults())
    let wideLibrary = Double(ContentView.libraryWidths.upperBound)
    layout.libraryWidth = wideLibrary

    // Half of a 2560x1440 screen: both sidebars stay open and clamp symmetrically
    // so the center page never falls below `ContentView.pageMinimumWidth`.
    layout.windowWidth = 1280
    #expect(layout.isLibraryShown)
    #expect(layout.isInspectorShown)
    #expect(
        layout.maxLibraryColumnWidth + ContentView.libraryInset
            + ContentView.pageMinimumWidth + layout.maxInspectorColumnWidth == 1280)

    // Clamped geometry updates at 1280 must not clobber the reader's wider preference.
    layout.recordLibraryWidth(layout.maxLibraryColumnWidth)
    layout.recordInspectorWidth(layout.maxInspectorColumnWidth)
    #expect(layout.libraryWidth == wideLibrary)

    // At the default width, sidebars can widen up to half the remaining room.
    layout.windowWidth = Double(WindowLayout.defaultSize.width)
    #expect(layout.maxInspectorColumnWidth == 475)
    #expect(
        layout.maxLibraryColumnWidth + ContentView.libraryInset
            + ContentView.pageMinimumWidth + layout.maxInspectorColumnWidth
            == WindowLayout.defaultSize.width)

    // Narrower single-sidebar width: only one sidebar is open, so the full spare room applies.
    layout.windowWidth = 1000
    #expect(layout.isLibraryShown)
    #expect(!layout.isInspectorShown)
    #expect(
        layout.maxLibraryColumnWidth
            == 1000 - ContentView.pageMinimumWidth - ContentView.libraryInset)

    // Dragging narrower within the ceiling updates both paired widths.
    layout.windowWidth = 1600
    #expect(layout.maxLibraryColumnWidth == ContentView.libraryWidths.upperBound)
    #expect(layout.maxInspectorColumnWidth == EntryView.inspectorWidths.upperBound)
    layout.recordLibraryWidth(440)
    #expect(layout.libraryWidth == 440)
    #expect(layout.inspectorWidth == 440 + Double(ContentView.libraryInset))
}

@MainActor
@Test func resetToDefaultSizeRestoresSidebarsAndCenteredDefaults() {
    let defaults = MemoryDefaults()
    let layout = WindowLayout(defaults: defaults)

    layout.showsLibrary = false
    layout.showsInspector = false
    layout.libraryWidth = 450
    layout.windowWidth = 1000
    layout.isInspectorShown = true
    #expect(layout.isInspectorShown)
    #expect(!layout.isLibraryShown)

    layout.resetToDefaultSize()
    #expect(layout.showsLibrary)
    #expect(layout.showsInspector)
    #expect(layout.isLibraryShown)
    #expect(!layout.isInspectorShown)
    #expect(layout.libraryWidth == Double(ContentView.idealLibraryWidth))
    #expect(layout.inspectorWidth == Double(EntryView.idealInspectorWidth))

    layout.windowWidth = Double(WindowLayout.defaultSize.width)
    #expect(layout.isLibraryShown)
    #expect(layout.isInspectorShown)

    let reloaded = WindowLayout(defaults: defaults)
    #expect(reloaded.showsLibrary)
    #expect(reloaded.showsInspector)
    #expect(reloaded.libraryWidth == Double(ContentView.idealLibraryWidth))
    #expect(reloaded.inspectorWidth == Double(EntryView.idealInspectorWidth))

    let leftMargin = ContentView.idealLibraryWidth + ContentView.libraryInset
    let rightMargin = EntryView.idealInspectorWidth
    #expect(leftMargin == rightMargin)
    let centerWidth = WindowLayout.defaultSize.width - leftMargin - rightMargin
    let expectedCenterWidth =
        EntryView.readingWidth(textSize: ReadingSettings.defaultTextSize) + 2 * Spacing.page
    #expect(centerWidth == expectedCenterWidth)
    #expect(WindowLayout.defaultSize.height == WindowLayout.defaultHeight)
}
