// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Centers the main window at its default size and snaps live AppKit split dividers
/// back to the symmetric defaults once any hidden panes finish uncollapsing.
@MainActor
final class WindowResetCoordinator {
    private var resetTask: Task<Void, Never>?
    private weak var attachedWindow: NSWindow?
    private var signalEvent: (@MainActor () -> Void)?

    func attach(_ window: NSWindow?) {
        guard let window else { return }
        attachedWindow = window
        signalEvent?()
    }

    func reset(layout: WindowLayout, openMainWindow: @escaping @MainActor () -> Void) {
        let previous = resetTask
        previous?.cancel()
        resetTask = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.performReset(layout: layout, openMainWindow: openMainWindow)
        }
    }

    private func performReset(layout: WindowLayout, openMainWindow: () -> Void) async {
        guard
            let window = await ensureVisibleWindow(
                layout: layout,
                openMainWindow: openMainWindow
            )
        else { return }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        centerAtDefaultSizeIfWindowed(window)

        await waitUntilWindowBoundsPropagate(in: window)
        guard !Task.isCancelled, window.isVisible else { return }

        if let contentWidth = window.contentView?.bounds.width, contentWidth > 0 {
            layout.windowWidth = Double(contentWidth)
        }
        layout.isResettingSize = true
        defer { layout.isResettingSize = false }
        layout.resetToDefaultSize()

        await waitUntilSplitPanesSettle(in: window, layout: layout)
        guard !Task.isCancelled, window.isVisible, !window.isMiniaturized,
            let root = window.contentView
        else { return }

        let (sidebarController, inspectorController) = Self.splitControllers(in: root)
        guard let sidebarController else { return }
        snapDividers(
            sidebarController: sidebarController,
            inspectorController: inspectorController
        )
        await nextRunLoopTurn()
    }

    private func waitUntilWindowBoundsPropagate(in window: NSWindow) async {
        window.layoutIfNeeded()
        await nextRunLoopTurn()
        _ = await waitUntil(
            timeout: .milliseconds(500),
            observing: [
                NSWindow.didResizeNotification,
                NSSplitView.didResizeSubviewsNotification,
            ]
        ) {
            Self.areWindowBoundsPropagated(in: window)
        }
    }

    private static func areWindowBoundsPropagated(in window: NSWindow) -> Bool {
        guard window.isVisible, let root = window.contentView else { return true }
        let targetWidth = root.bounds.width
        let minInspectorContainerWidth = max(
            0,
            targetWidth - ContentView.idealLibraryWidth - ContentView.libraryInset - 1
        )
        let (sidebar, inspector) = splitControllers(in: root)
        let sidebarReady = sidebar.map { $0.splitView.bounds.width >= targetWidth - 1 } ?? true
        let inspectorReady =
            inspector.map {
                guard $0.splitView.bounds.width >= minInspectorContainerWidth else {
                    return false
                }
                guard let item = $0.splitViewItems.last, item.isCollapsed else { return true }
                let view = item.viewController.view
                return view.window == nil || view.isHiddenOrHasHiddenAncestor
            } ?? true
        return sidebarReady && inspectorReady
    }

    private func nextRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func ensureVisibleWindow(
        layout: WindowLayout,
        openMainWindow: () -> Void
    ) async -> NSWindow? {
        if let window = visibleOrMiniaturizedAttachedWindow {
            return window
        }
        layout.resetToDefaultSize()
        openMainWindow()
        await nextRunLoopTurn()
        _ = await waitUntil(
            timeout: .seconds(1),
            observing: [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didExposeNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ]
        ) { [weak self] in
            self?.visibleOrMiniaturizedAttachedWindow != nil
        }
        return visibleOrMiniaturizedAttachedWindow
    }

    private var visibleOrMiniaturizedAttachedWindow: NSWindow? {
        guard let window = attachedWindow, window.isVisible || window.isMiniaturized else {
            return nil
        }
        return window
    }

    private func centerAtDefaultSizeIfWindowed(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
            let screen = window.screen ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let target = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: WindowLayout.defaultSize)
        ).size
        let width = min(target.width, visible.width)
        let height = min(target.height, visible.height)
        let x = visible.minX + floor((visible.width - width) / 2)
        let y = visible.minY + floor((visible.height - height) / 2)
        window.setFrame(
            NSRect(x: x, y: y, width: width, height: height),
            display: true,
            animate: false
        )
    }

    private func waitUntilSplitPanesSettle(in window: NSWindow, layout: WindowLayout) async {
        await nextRunLoopTurn()
        _ = await waitUntil(
            timeout: .milliseconds(750),
            observing: [
                NSSplitView.didResizeSubviewsNotification,
                NSWindow.didResizeNotification,
            ]
        ) {
            guard !Task.isCancelled, window.isVisible, !window.isMiniaturized,
                let root = window.contentView
            else { return true }
            return isLayoutSettled(in: root, windowWidth: window.frame.width, layout: layout)
        }
    }

    private func waitUntil(
        timeout: Duration,
        observing names: [Notification.Name],
        condition: @MainActor () -> Bool
    ) async -> Bool {
        if condition() { return true }
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield()
            }
        }
        signalEvent = { continuation.yield() }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        defer {
            signalEvent = nil
            timeoutTask.cancel()
            continuation.finish()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        return await withTaskCancellationHandler {
            for await _ in stream {
                if Task.isCancelled { return false }
                if condition() { return true }
            }
            return !Task.isCancelled && condition()
        } onCancel: {
            continuation.finish()
        }
    }

    private func isLayoutSettled(
        in root: NSView,
        windowWidth: CGFloat,
        layout: WindowLayout
    ) -> Bool {
        let (sidebarController, inspectorController) = Self.splitControllers(in: root)
        guard let sidebarController,
            let sidebarItem = sidebarController.splitViewItems.first
        else { return true }
        return isSidebarSettled(in: sidebarItem, layout: layout)
            && isInspectorSettled(
                in: inspectorController,
                windowWidth: windowWidth,
                layout: layout
            )
    }

    private func isSidebarSettled(in item: NSSplitViewItem, layout: WindowLayout) -> Bool {
        guard layout.isLibraryShown else { return true }
        guard !item.isCollapsed else { return false }
        let view = item.viewController.view
        let maxX = view.convert(view.bounds, to: nil).maxX
        let targetWidth = ContentView.idealLibraryWidth
        return maxX >= targetWidth + ContentView.libraryInset - 1
            && view.bounds.width <= targetWidth + 1
    }

    private func isInspectorSettled(
        in controller: NSSplitViewController?,
        windowWidth: CGFloat,
        layout: WindowLayout
    ) -> Bool {
        guard let controller,
            let item = controller.splitViewItems.last,
            layout.isInspectorShown
        else { return true }
        guard !item.isCollapsed else { return false }
        let view = item.viewController.view
        let minX = view.convert(view.bounds, to: nil).minX
        let targetWidth = EntryView.idealInspectorWidth
        return minX + targetWidth <= windowWidth + 1
            && view.bounds.width >= targetWidth - 1
            && view.bounds.width <= targetWidth + 1
    }

    private func snapDividers(
        sidebarController: NSSplitViewController,
        inspectorController: NSSplitViewController?
    ) {
        if let sidebarItem = sidebarController.splitViewItems.first, !sidebarItem.isCollapsed {
            // The sidebar's split view holds both the library content (max idealLibraryWidth)
            // and its outer leading inset, so divider 0 sits at the sum of the two.
            sidebarController.splitView.setPosition(
                ContentView.idealLibraryWidth + ContentView.libraryInset,
                ofDividerAt: 0
            )
        }
        if let inspectorController,
            let inspectorItem = inspectorController.splitViewItems.last,
            !inspectorItem.isCollapsed,
            inspectorController.splitViewItems.count >= 2
        {
            let dividerIndex = inspectorController.splitViewItems.count - 2
            inspectorController.splitView.setPosition(
                inspectorController.splitView.bounds.width - EntryView.idealInspectorWidth,
                ofDividerAt: dividerIndex
            )
        }
    }

    static func splitControllers(
        in root: NSView
    ) -> (sidebar: NSSplitViewController?, inspector: NSSplitViewController?) {
        var sidebar: NSSplitViewController?
        var inspector: NSSplitViewController?
        func walk(_ view: NSView) {
            if let splitView = view as? NSSplitView,
                let controller = splitView.delegate as? NSSplitViewController
            {
                if controller.splitViewItems.first?.behavior == .sidebar {
                    sidebar = controller
                }
                if controller.splitViewItems.last?.behavior == .inspector {
                    inspector = controller
                }
            }
            for child in view.subviews {
                walk(child)
            }
        }
        walk(root)
        return (sidebar, inspector)
    }
}

struct MainWindowBridge: NSViewRepresentable {
    let onAttach: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.onAttach = onAttach
        if let window = view.window {
            onAttach(window)
        }
    }

    final class BridgeView: NSView {
        var onAttach: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onAttach?(window)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
