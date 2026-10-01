// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Reads playback away from the rows so only a change of paragraph updates them.
struct Follow: View {
    let player: Player
    let starts: [TimeInterval]
    let isEnabled: Bool
    let update: (Int?) -> Void
    let scroll: (Int) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: playing, initial: true) { _, paragraph in
                update(paragraph)
                guard isEnabled, let paragraph else { return }
                scroll(paragraph)
            }
            .onChange(of: isEnabled) { _, on in
                guard on, let paragraph = playing else { return }
                scroll(paragraph)
            }
    }

    private var playing: Int? {
        guard player.isOpen else { return nil }
        return TranscriptNavigation.paragraph(playingAt: player.position, starts: starts)
    }
}

/// Which paragraph plays, and when following needs to scroll to it.
nonisolated enum TranscriptNavigation {
    static func needsScroll(frame: CGRect?, height: CGFloat) -> Bool {
        guard let frame, height > 0 else { return true }
        // Long paragraphs only need their opening lines in view.
        return frame.minY < 0 || frame.minY + min(frame.height, 80) > height
    }

    /// Whether a row is the one at the top of the page: across its top edge, or
    /// just below it, within the spacing before the next row.
    static func isAtTop(_ frame: CGRect, spacing: CGFloat) -> Bool {
        frame.maxY > 0 && frame.minY <= spacing
    }

    /// The paragraph playing at `position`, with the half second of slack a jump takes.
    static func paragraph(playingAt position: TimeInterval, starts: [TimeInterval]) -> Int? {
        starts.lastIndex { $0 <= position + 0.5 }
    }

    /// The paragraph `offset` places away, kept inside the transcript. With no
    /// current paragraph, as before the first one, both directions start at
    /// the first one.
    static func paragraph(from current: Int?, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return min(max(0, current + offset), count - 1)
    }
}

/// Tells the reader's scrolling from the jumps of following. Wheel and
/// trackpad scrolls are seen as events, since a mouse wheel starts no live
/// scroll; dragging the scroller starts one.
struct ManualScroll: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Observer {
        Observer(action: action)
    }

    func updateNSView(_ view: Observer, context: Context) {
        view.action = action
    }

    static func dismantleNSView(_ view: Observer, coordinator: ()) {
        view.stopMonitoring()
    }

    final class Observer: NSView {
        var action: () -> Void
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrolled(_:)),
                name: NSScrollView.willStartLiveScrollNotification, object: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.wheeled(event)
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Fingers resting on the trackpad send events that move nothing.
        private func wheeled(_ event: NSEvent) {
            guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0,
                event.window === window, let scroll = enclosingScrollView,
                scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            else { return }
            action()
        }

        @objc private func scrolled(_ notification: Notification) {
            guard let scroll = notification.object as? NSScrollView,
                scroll === enclosingScrollView
            else { return }
            action()
        }
    }
}
