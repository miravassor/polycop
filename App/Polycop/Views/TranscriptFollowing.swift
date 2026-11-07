// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// How the transcript keeps up with playback: one choice, since scrolling and
/// the cursor were two settings in two places that read as one feature.
nonisolated enum Following: String, CaseIterable {
    case off
    /// Scrolls to the paragraph being played.
    case page
    /// Scrolls, and takes the text cursor along with the word heard.
    case cursor

    static let key = "followPlayback"
    /// The cursor setting of 0.4.0, which Settings held on its own.
    static let cursorKey = "cursorFollowsPlayback"

    /// What the reader chose, which starts from the cursor setting of 0.4.0
    /// when it was on.
    init(stored defaults: UserDefaults) {
        if let chosen = defaults.string(forKey: Self.key).flatMap(Following.init(rawValue:)) {
            self = chosen
        } else {
            self = defaults.bool(forKey: Self.cursorKey) ? .cursor : .page
        }
    }

    /// Whether a click or typing in the text stops the scrolling. With the
    /// cursor following, editing is what following is for.
    var stopsWhenEditing: Bool { self != .cursor }

    /// What applies to a transcript: with no word timings the cursor has nothing
    /// to follow, so the page alone does, and a click stops it as usual.
    func effective(hasTimedWords: Bool) -> Following {
        self == .cursor && !hasTimedWords ? .page : self
    }

    var name: String {
        switch self {
        case .off: String(localized: "Off")
        case .page: String(localized: "Page")
        case .cursor: String(localized: "Page and Cursor")
        }
    }
}

/// Follow's choice, inside a menu: the Text menu above the page and the Playback
/// menu both hold it.
struct FollowChoice: View {
    @Bindable var reading: ReadingSettings
    let lacksTimedWords: Bool

    var body: some View {
        Picker("Follow", selection: $reading.following) {
            ForEach(Following.allCases, id: \.self) { choice in
                Text(choice.name)
                    .tag(choice)
                    .selectionDisabled(choice == .cursor && lacksTimedWords)
            }
        }
        .pickerStyle(.inline)
        if lacksTimedWords {
            Text("Page and Cursor needs word timings.")
        }
    }
}

#Preview("Follow's choice") {
    Menu("Text") {
        FollowChoice(reading: ReadingSettings(defaults: MemoryDefaults()), lacksTimedWords: true)
    }
    .padding(Spacing.sheet)
}

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

    /// The paragraph to bring back to: before the first one opens, as a late
    /// start can leave it, the first one, so that coming back always moves the page.
    static func paragraph(returningTo position: TimeInterval, starts: [TimeInterval]) -> Int? {
        paragraph(playingAt: position, starts: starts) ?? (starts.isEmpty ? nil : 0)
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

        /// Whether a wheel or trackpad event is the reader scrolling. Fingers
        /// resting on the trackpad send events that move nothing, and a flick
        /// coasts on after they lift: its first events said so already, and
        /// the rest would undo Return to Playback pressed during the coast.
        static func isReaderScrolling(_ event: NSEvent) -> Bool {
            (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0)
                && event.momentumPhase.isEmpty
        }

        private func wheeled(_ event: NSEvent) {
            guard Self.isReaderScrolling(event),
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
