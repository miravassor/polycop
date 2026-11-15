// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import Testing

@testable import Polycop

private struct ResetTestSplitView: View {
    @Bindable var layout: WindowLayout

    private var maxLibraryWidth: CGFloat {
        layout.isResettingSize ? ContentView.idealLibraryWidth : layout.maxLibraryColumnWidth
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: Binding(
                get: { layout.isLibraryShown ? .all : .detailOnly },
                set: { layout.isLibraryShown = ($0 != .detailOnly) }
            )
        ) {
            Color.clear
                .navigationSplitViewColumnWidth(
                    min: ContentView.libraryWidths.lowerBound,
                    ideal: min(CGFloat(layout.libraryWidth), maxLibraryWidth),
                    max: maxLibraryWidth
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
    window.setContentSize(NSSize(width: 900, height: 600))
    window.setFrameOrigin(NSPoint(x: 40, y: 40))
    #expect(!window.isVisible)

    var openCalls = 0
    let coordinator = WindowResetCoordinator()
    coordinator.reset(layout: layout) {
        openCalls += 1
        coordinator.attach(window)
        window.orderFront(nil)
    }

    await waitUntilSettled {
        guard window.isVisible, !layout.isResettingSize,
            layout.isLibraryShown, layout.isInspectorShown,
            let root = window.contentView
        else { return false }
        let controllers = WindowResetCoordinator.splitControllers(in: root)
        guard let sidebar = controllers.sidebar, let inspector = controllers.inspector,
            sidebar.splitViewItems.first?.isCollapsed == false,
            inspector.splitViewItems.last?.isCollapsed == false
        else { return false }
        let sidebarWidth = sidebar.splitViewItems.first?.viewController.view.frame.width ?? 0
        let inspectorWidth = inspector.splitViewItems.last?.viewController.view.frame.width ?? 0
        return abs(sidebarWidth - ContentView.idealLibraryWidth) <= 1
            && abs(inspectorWidth - EntryView.idealInspectorWidth) <= 1
    }

    #expect(openCalls == 1)
    #expect(window.isVisible)
    assertCenteredDefaultFrame(of: window)
    #expect(layout.showsLibrary)
    #expect(layout.showsInspector)
    #expect(layout.isLibraryShown)
    #expect(layout.isInspectorShown)
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
