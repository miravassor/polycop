// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Testing

@testable import Polycop

/// Two paragraphs of a page in `window`, each the text view the editor makes.
@MainActor
private func twoParagraphs(in window: NSWindow) -> (WordTextView, WordTextView) {
    let first = ParagraphEditor.makeTextView()
    let second = ParagraphEditor.makeTextView()
    first.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    second.frame = NSRect(x: 0, y: 150, width: 300, height: 100)
    first.string = "Bonjour à tous."
    second.string = "Le cours commence."
    for view in [first, second] { window.contentView?.addSubview(view) }
    return (first, second)
}

/// An editor's coordinator for `view`, counting the times it says the reader
/// is in its paragraph.
@MainActor
private final class Activations {
    private(set) var count = 0
    private var coordinator: ParagraphEditor.Coordinator?

    init(of view: WordTextView) {
        coordinator = ParagraphEditor(
            text: view.string, original: view.string, size: 13, isEditable: true, edit: { _ in },
            activate: { [unowned self] in count += 1 }
        ).makeCoordinator()
        view.delegate = coordinator
    }
}

/// The page reads as one text with one selection, in the paragraph being
/// edited: clicking into another, leaving the text or a row being hidden leaves
/// none behind. And dropping it is not the reader moving the cursor there.
@MainActor
@Test func leavingAParagraphLeavesNothingSelectedInIt() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    let (first, second) = twoParagraphs(in: window)
    let activations = Activations(of: first)

    window.makeFirstResponder(first)
    first.setSelectedRange(NSRange(location: 0, length: 7))
    #expect(activations.count == 1)
    window.makeFirstResponder(second)
    #expect(first.selectedRange() == NSRange(location: 0, length: 0))
    #expect(activations.count == 1)

    second.setSelectedRange(NSRange(location: 3, length: 5))
    window.makeFirstResponder(nil)
    #expect(second.selectedRange() == NSRange(location: 3, length: 0))

    // A row the list hides, as after a jump, was left as well.
    defer { WordTextView.lostCursor = false }
    window.makeFirstResponder(first)
    first.setSelectedRange(NSRange(location: 8, length: 1))
    #expect(activations.count == 2)
    first.isHidden = true
    #expect(window.firstResponder !== first)
    #expect(first.selectedRange() == NSRange(location: 8, length: 0))
    #expect(activations.count == 2)
}

/// Text a drag moves to another paragraph is taken out of the one it left as
/// the drag ends, which is not the reader editing there: the cursor is where
/// the text landed.
@MainActor
@Test func textTakenOutOfAParagraphLeftIsNotTheReaderEditingIt() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    let (first, second) = twoParagraphs(in: window)
    let activations = Activations(of: first)
    window.makeFirstResponder(first)
    #expect(activations.count == 1)
    window.makeFirstResponder(second)

    // As AppKit does at the end of a drag that moved the selection away.
    first.setSelectedRange(NSRange(location: 0, length: 8))
    first.delete(nil)
    #expect(first.string == "à tous.")
    #expect(activations.count == 1)
}

/// A window that reads as the key one, the only one where AppKit shows a
/// text's cursor: the window of a test never is.
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Whether a text view shows its cursor, which AppKit draws in a view of its own.
@MainActor
private func showsCursor(_ view: NSView) -> Bool {
    view.subviews.contains { subview in
        guard let cursor = subview as? NSTextInsertionIndicator else { return showsCursor(subview) }
        return cursor.displayMode != .hidden
    }
}

/// One cursor on the page, in the paragraph being edited: the one left drops
/// its selection without a cursor showing there again.
@MainActor
@Test func aParagraphLeftShowsNoCursor() {
    let window = KeyWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let (first, second) = twoParagraphs(in: window)

    window.makeFirstResponder(first)
    #expect(showsCursor(first))
    first.setSelectedRange(NSRange(location: 0, length: 7))
    window.makeFirstResponder(second)
    #expect(!showsCursor(first))
    #expect(showsCursor(second))

    // Left with the cursor alone, nothing selected.
    window.makeFirstResponder(first)
    #expect(showsCursor(first))
    window.makeFirstResponder(nil)
    #expect(!showsCursor(first))
}

/// A drop as AppKit describes it to the view under the pointer.
@MainActor
private final class Drop: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSource: Any?
    let draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move, .generic]
    var draggedImageLocation: NSPoint { draggingLocation }
    let draggedImage: NSImage? = nil
    let draggingSequenceNumber = 1
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight = NSSpringLoadingHighlight.none

    init(of text: String, from source: NSView, at location: NSPoint, in window: NSWindow) {
        draggingDestinationWindow = window
        draggingSource = source
        draggingLocation = location
        draggingPasteboard.clearContents()
        draggingPasteboard.setString(text, forType: .string)
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

/// Text dragged from a paragraph and dropped in another is selected where it
/// lands, with the focus, and nothing stays selected where it came from.
@MainActor
@Test func textDroppedInAParagraphTakesTheFocusThere() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    let (first, second) = twoParagraphs(in: window)
    window.makeFirstResponder(first)
    first.setSelectedRange(NSRange(location: 0, length: 7))

    let drop = Drop(
        of: "Bonjour", from: first, at: second.convert(NSPoint(x: 2, y: 2), to: nil), in: window)
    defer { drop.draggingPasteboard.releaseGlobally() }
    #expect(second.draggingEntered(drop) == .copy)
    #expect(second.prepareForDragOperation(drop))
    #expect(second.performDragOperation(drop))
    second.concludeDragOperation(drop)

    #expect(second.string == "BonjourLe cours commence.")
    #expect(window.firstResponder === second)
    #expect(second.selectedRange() == NSRange(location: 0, length: 7))
    #expect(first.selectedRange().length == 0)
}
