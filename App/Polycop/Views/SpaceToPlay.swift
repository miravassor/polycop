// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Space plays or pauses, as in any player, unless the keyboard is somewhere
/// Space already means something: text being edited, or a button reached with
/// the keyboard. Other windows, sheets and popovers keep Space to themselves.
struct SpaceToPlay: NSViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.isEnabled = isEnabled
        view.action = action
    }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) {
        view.stopWatching()
    }

    final class Watcher: NSView {
        var isEnabled = true
        var action: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, plays(on: event) else { return event }
                // Holding Space plays or pauses once.
                if !event.isARepeat { action() }
                return nil
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func plays(on event: NSEvent) -> Bool {
            guard isEnabled, let window, event.window === window,
                event.charactersIgnoringModifiers == " ",
                event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting(.capsLock).isEmpty
            else { return false }
            switch window.firstResponder {
            case let text as NSText: return !text.isEditable
            case is NSTableView: return true
            case is NSControl: return false
            default: return true
            }
        }
    }
}
