// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
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

private struct ResetTestSplitView: View {
    @Bindable var layout: WindowLayout

    var body: some View {
        NavigationSplitView(
            columnVisibility: Binding(
                get: { layout.isLibraryShown ? .all : .detailOnly },
                set: { layout.isLibraryShown = ($0 != .detailOnly) }
            )
        ) {
            Color.clear
                .navigationSplitViewColumnWidth(
                    min: ContentView.idealLibraryWidth, ideal: layout.libraryWidth,
                    max: layout.isResettingSize ? ContentView.idealLibraryWidth : 512
                )
        } detail: {
            Color.clear
                .inspector(isPresented: $layout.isInspectorShown) {
                    Color.clear.modifier(InspectorColumn(layout: layout))
                }
        }
        .frame(minWidth: ContentView.pageMinimumWidth, minHeight: 600)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) {
            layout.windowWidth = Double($0)
        }
    }
}

@MainActor
private func makeResetTestWindow(layout: WindowLayout) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 40, y: 40, width: 900, height: 600),
        styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    window.titleVisibility = .hidden
    window.contentView = NSHostingView(rootView: ResetTestSplitView(layout: layout))
    return window
}

@MainActor
private func waitUntilSettled(_ condition: () -> Bool) async {
    for _ in 0..<60 where !condition() {
        try? await Task.sleep(for: .milliseconds(30))
    }
}

@MainActor
private func areSplitPanesCollapsed(in window: NSWindow) -> Bool {
    guard let root = window.contentView else { return false }
    let controllers = WindowResetCoordinator.splitControllers(in: root)
    guard let sidebarItem = controllers.sidebar?.splitViewItems.first,
        let inspectorItem = controllers.inspector?.splitViewItems.last,
        sidebarItem.isCollapsed, inspectorItem.isCollapsed
    else { return false }
    let sidebarView = sidebarItem.viewController.view
    let inspectorView = inspectorItem.viewController.view
    return (sidebarView.window == nil || sidebarView.isHiddenOrHasHiddenAncestor)
        && (inspectorView.window == nil || inspectorView.isHiddenOrHasHiddenAncestor)
}

@MainActor
private func assertCenteredDefaultFrame(of window: NSWindow) {
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
    let target = window.frameRect(
        forContentRect: NSRect(origin: .zero, size: WindowLayout.defaultSize)
    ).size
    let expectedWidth = min(target.width, visible.width)
    let expectedHeight = min(target.height, visible.height)
    let expectedX = visible.minX + floor((visible.width - expectedWidth) / 2)
    let expectedY = visible.minY + floor((visible.height - expectedHeight) / 2)

    #expect(abs(window.frame.width - expectedWidth) <= 1)
    #expect(abs(window.frame.height - expectedHeight) <= 1)
    #expect(abs(window.frame.minX - expectedX) <= 1)
    #expect(abs(window.frame.minY - expectedY) <= 1)
}

@MainActor
@Test func windowResetCoordinatorCentersCollapsedWindowAndRestoresSplitWidths() async {
    let layout = WindowLayout(defaults: MemoryDefaults())
    let window = makeResetTestWindow(layout: layout)
    window.orderFront(nil)
    defer { window.close() }

    await waitUntilSettled {
        guard let root = window.contentView else { return false }
        let controllers = WindowResetCoordinator.splitControllers(in: root)
        return controllers.sidebar != nil && controllers.inspector != nil
    }

    layout.showsLibrary = false
    layout.showsInspector = false
    layout.libraryWidth = 450
    await waitUntilSettled { areSplitPanesCollapsed(in: window) }

    window.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
    let coordinator = WindowResetCoordinator()
    coordinator.attach(window)
    coordinator.reset(layout: layout) {}

    await waitUntilSettled {
        guard !layout.isResettingSize, let root = window.contentView else { return false }
        let controllers = WindowResetCoordinator.splitControllers(in: root)
        return controllers.sidebar?.splitViewItems.first?.isCollapsed == false
            && controllers.inspector?.splitViewItems.last?.isCollapsed == false
    }

    #expect(!layout.isResettingSize)
    assertCenteredDefaultFrame(of: window)
    #expect(layout.showsLibrary)
    #expect(layout.showsInspector)
    #expect(layout.libraryWidth == Double(ContentView.idealLibraryWidth))
    #expect(layout.inspectorWidth == Double(EntryView.idealInspectorWidth))

    if let root = window.contentView {
        let (sidebar, inspector) = WindowResetCoordinator.splitControllers(in: root)
        let sidebarWidth = sidebar?.splitViewItems.first?.viewController.view.frame.width ?? 0
        let inspectorWidth = inspector?.splitViewItems.last?.viewController.view.frame.width ?? 0
        #expect(abs(sidebarWidth - ContentView.idealLibraryWidth) <= 1)
        #expect(abs(inspectorWidth - EntryView.idealInspectorWidth) <= 1)
    }
}

@MainActor
@Test func windowResetCoordinatorReopensHiddenMainWindow() async {
    let layout = WindowLayout(defaults: MemoryDefaults())
    layout.showsLibrary = false
    layout.showsInspector = false
    layout.libraryWidth = 450

    let window = makeResetTestWindow(layout: layout)
    defer { window.close() }
    #expect(!window.isVisible)

    window.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
    var openCalls = 0
    let coordinator = WindowResetCoordinator()
    coordinator.reset(layout: layout) {
        openCalls += 1
        coordinator.attach(window)
        window.orderFront(nil)
    }

    await waitUntilSettled {
        window.isVisible && !layout.isResettingSize && layout.isLibraryShown
    }

    #expect(openCalls == 1)
    #expect(window.isVisible)
    #expect(layout.showsLibrary)
    #expect(layout.showsInspector)
    #expect(layout.libraryWidth == Double(ContentView.idealLibraryWidth))
    #expect(layout.inspectorWidth == Double(EntryView.idealInspectorWidth))
}
