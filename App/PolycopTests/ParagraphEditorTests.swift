// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Testing

@testable import Polycop

/// Typing stays in the text view: the model has it after a pause, when it is
/// handed over, or when the paragraph goes away, never at each key.
@MainActor
@Test func typingReachesTheModelOnceHandedOver() async throws {
    var edits: [String] = []
    var keys = 0
    let editor = ParagraphEditor(
        text: "Bonjour.", original: "Bonjour.", size: 13, isEditable: true,
        edit: { edits.append($0) }, typing: { keys += 1 })
    let coordinator = editor.makeCoordinator()
    let view = WordTextView()
    func type(_ text: String) {
        view.string = text
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
    }

    type("Bonjour à tous.")
    #expect(keys == 1)
    #expect(edits.isEmpty)
    TypingBuffer.flush()
    #expect(edits == ["Bonjour à tous."])

    type("Bonsoir à tous.")
    try await Task.sleep(for: .seconds(1))
    #expect(edits == ["Bonjour à tous.", "Bonsoir à tous."])

    type("Bonsoir à toutes.")
    ParagraphEditor.dismantleNSView(view, coordinator: coordinator)
    #expect(edits.last == "Bonsoir à toutes.")
    TypingBuffer.flush()
    #expect(edits.count == 3)
}

/// A control reached with the keyboard, as buttons are with Full Keyboard Access.
private final class FocusableControl: NSControl {
    override var acceptsFirstResponder: Bool { true }
}

/// Space plays or pauses outside the text, types a space inside it, and leaves
/// modified keys, focused controls and other windows alone. Escape leaves the text.
@MainActor
@Test func spacePlaysOutsideTheText() throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    let watcher = SpaceToPlay.Watcher()
    let text = WordTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let field = NSTextField(frame: NSRect(x: 0, y: 120, width: 200, height: 22))
    let list = NSTableView(frame: NSRect(x: 0, y: 150, width: 200, height: 100))
    let control = FocusableControl(frame: NSRect(x: 220, y: 0, width: 40, height: 20))
    for view in [watcher, text, field, list, control] { window.contentView?.addSubview(view) }
    func key(_ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 49))
    }

    #expect(watcher.plays(on: try key(" ")))
    #expect(!watcher.plays(on: try key(" ", .shift)))
    #expect(!watcher.plays(on: try key("a")))
    window.makeFirstResponder(text)
    #expect(!watcher.plays(on: try key(" ")))
    text.cancelOperation(nil)
    #expect(watcher.plays(on: try key(" ")))
    text.isEditable = false
    window.makeFirstResponder(text)
    #expect(watcher.plays(on: try key(" ")))
    window.makeFirstResponder(field)
    #expect(!watcher.plays(on: try key(" ")))
    window.makeFirstResponder(list)
    #expect(watcher.plays(on: try key(" ")))
    window.makeFirstResponder(control)
    #expect(!watcher.plays(on: try key(" ")))
    window.makeFirstResponder(nil)
    watcher.isEnabled = false
    #expect(!watcher.plays(on: try key(" ")))
}
