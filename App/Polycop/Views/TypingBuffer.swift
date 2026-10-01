// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Typing held in paragraph editors before the model has it. A click, a
/// shortcut, a menu or quitting hands it over first, so whatever reads a
/// transcript reads what was typed.
enum TypingBuffer {
    /// How long typing waits before reaching the model on its own.
    static let pause: Duration = .milliseconds(500)
    private static var editors: [ObjectIdentifier: ParagraphEditor.Coordinator] = [:]
    private static var isWatching = false

    static func hold(_ editor: ParagraphEditor.Coordinator) {
        editors[ObjectIdentifier(editor)] = editor
        watch()
    }

    static func release(_ editor: ParagraphEditor.Coordinator) {
        editors[ObjectIdentifier(editor)] = nil
    }

    /// Hands every held text to the model.
    static func flush() {
        for editor in editors.values { editor.commit() }
    }

    /// Plain keys go on typing; anything else may act on the transcript.
    private static func watch() {
        guard !isWatching else { return }
        isWatching = true
        NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { event in
            if event.type != .keyDown
                || !event.modifierFlags.isDisjoint(with: [.command, .control])
            {
                flush()
            }
            return event
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { flush() }
        }
    }
}
