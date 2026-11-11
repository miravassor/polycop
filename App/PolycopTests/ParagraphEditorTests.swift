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
    for _ in 0..<100 where edits.count < 2 {
        try await Task.sleep(for: .milliseconds(50))
    }
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

/// While the reader edits, the cursor follows the word heard into its
/// paragraph, but not after a click placed it, nor over a selection.
@MainActor
@Test func theCursorFollowsTheWordHeardAfterTyping() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    let first = WordTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let second = WordTextView(frame: NSRect(x: 0, y: 150, width: 300, height: 100))
    first.string = "Bonjour à tous."
    second.string = "Le cours commence."
    for view in [first, second] { window.contentView?.addSubview(view) }
    defer { WordTextView.holdsCursor = false }

    window.makeFirstResponder(first)
    WordTextView.holdsCursor = false
    second.follow(NSRange(location: 3, length: 5))
    #expect(window.firstResponder === second)
    #expect(second.selectedRange() == NSRange(location: 8, length: 0))

    WordTextView.holdsCursor = true
    second.follow(NSRange(location: 9, length: 8))
    #expect(second.selectedRange() == NSRange(location: 8, length: 0))

    WordTextView.holdsCursor = false
    second.setSelectedRange(NSRange(location: 0, length: 2))
    second.follow(NSRange(location: 9, length: 8))
    #expect(second.selectedRange() == NSRange(location: 0, length: 2))

    window.makeFirstResponder(nil)
    first.follow(NSRange(location: 0, length: 7))
    #expect(window.firstResponder === window)
}

/// After a jump, the row being edited is hidden with the cursor in it; the
/// paragraph heard then takes the cursor, which a reader who left the text
/// with Escape does not see happen.
@MainActor
@Test func theCursorFollowsPastTheRowItLeft() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    let first = WordTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let far = WordTextView(frame: NSRect(x: 0, y: 150, width: 300, height: 100))
    first.string = "Bonjour à tous."
    far.string = "Le cours commence."
    for view in [first, far] { window.contentView?.addSubview(view) }
    WordTextView.holdsCursor = false
    defer { WordTextView.lostCursor = false }

    window.makeFirstResponder(first)
    first.isHidden = true
    far.follow(NSRange(location: 3, length: 5))
    #expect(window.firstResponder === far)
    #expect(far.selectedRange() == NSRange(location: 8, length: 0))

    window.makeFirstResponder(nil)
    far.follow(NSRange(location: 9, length: 8))
    #expect(window.firstResponder === window)
}

/// The page reads as one text with one selection, in the paragraph being
/// edited: clicking into another, or leaving the text, leaves none behind. And
/// dropping it is not the reader moving the cursor there.
@MainActor
@Test func leavingAParagraphLeavesNothingSelectedInIt() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    let first = WordTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let second = WordTextView(frame: NSRect(x: 0, y: 150, width: 300, height: 100))
    first.string = "Bonjour à tous."
    second.string = "Le cours commence."
    for view in [first, second] { window.contentView?.addSubview(view) }
    var activations = 0
    let coordinator = ParagraphEditor(
        text: first.string, original: first.string, size: 13, isEditable: true, edit: { _ in },
        activate: { activations += 1 }
    ).makeCoordinator()
    first.delegate = coordinator

    window.makeFirstResponder(first)
    first.setSelectedRange(NSRange(location: 0, length: 7))
    #expect(activations == 1)
    window.makeFirstResponder(second)
    #expect(first.selectedRange() == NSRange(location: 0, length: 0))
    #expect(activations == 1)

    second.setSelectedRange(NSRange(location: 3, length: 5))
    window.makeFirstResponder(nil)
    #expect(second.selectedRange() == NSRange(location: 3, length: 0))
}

/// What is typed stays as typed, whatever the system's text input settings:
/// a curly apostrophe would hide a word from Find and course corrections.
@MainActor
@Test func theEditorTypesWhatIsTyped() {
    for view in [WordTextView(), WordTextView(frame: .zero, textContainer: NSTextContainer())] {
        #expect(!view.isAutomaticQuoteSubstitutionEnabled)
        #expect(!view.isAutomaticDashSubstitutionEnabled)
        #expect(!view.isAutomaticSpellingCorrectionEnabled)
        #expect(!view.isAutomaticTextReplacementEnabled)
    }
}

/// An accent typed with a dead key is not a correction until its letter
/// follows, so no pause hands it to the model on its own.
@MainActor
@Test func anAccentWaitingForItsLetterIsNotCommittedAfterAPause() {
    var edits: [String] = []
    let editor = ParagraphEditor(
        text: "pr", original: "pr", size: 13, isEditable: true, edit: { edits.append($0) })
    let coordinator = editor.makeCoordinator()
    // On TextKit 1, as the editor is: reaching the layout manager of a
    // TextKit 2 view switches it over and drops the marked text.
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer()
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    let view = WordTextView(frame: .zero, textContainer: container)
    view.string = "pr"
    view.setSelectedRange(NSRange(location: 2, length: 0))
    let changed = Notification(name: NSText.didChangeNotification, object: view)

    view.setMarkedText(
        "^", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    coordinator.textDidChange(changed)
    #expect(view.hasMarkedText())
    #expect(coordinator.commitAfterPause == nil)

    view.insertText("ê", replacementRange: view.markedRange())
    coordinator.textDidChange(changed)
    #expect(!view.hasMarkedText())
    #expect(coordinator.commitAfterPause != nil)
    TypingBuffer.flush()
    #expect(edits == ["prê"])
}

/// Play From Cursor plays from where the text cursor stands, as Option-click
/// does from where the pointer is.
@MainActor
@Test func playFromCursorPlaysFromTheCursor() {
    let view = WordTextView()
    view.string = "Bonjour à tous."
    var played: [Int] = []
    view.playFromCharacter = { index in
        played.append(index)
        return true
    }

    view.setSelectedRange(NSRange(location: 8, length: 0))
    view.playFromCursor(nil)

    #expect(played == [8])
}

/// Hiding the library with the focus on it, as a window opening with the library
/// hidden does, must not put the cursor in the text: Space would type there.
@MainActor
@Test func hidingTheFocusedViewLeavesTheTextAlone() throws {
    final class Focusable: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let library = Focusable(frame: NSRect(x: 0, y: 0, width: 50, height: 200))
    let text = WordTextView(frame: NSRect(x: 50, y: 0, width: 150, height: 200))
    window.contentView?.addSubview(library)
    window.contentView?.addSubview(text)
    library.nextKeyView = text
    text.nextKeyView = library
    window.orderBack(nil)
    try #require(window.makeFirstResponder(library))
    library.isHidden = true
    #expect(window.firstResponder !== text)
}

/// A paragraph that resizes must not scroll the page, which AppKit does only in
/// the real window, checked there. A jump to a match still has to scroll a
/// paragraph not being edited.
@MainActor
@Test func aParagraphNotBeingEditedStillScrollsWhenAsked() {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let page = FlippedPage(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
    let text = WordTextView(frame: NSRect(x: 0, y: 200, width: 300, height: 60))
    page.addSubview(text)
    scroll.documentView = page
    #expect(text.scrollToVisible(NSRect(x: 0, y: 0, width: 10, height: 20)))
    #expect(scroll.contentView.bounds.origin.y > 0)
}

private final class FlippedPage: NSView {
    override var isFlipped: Bool { true }
}
