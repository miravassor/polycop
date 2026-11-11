// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// A text view that plays the recording from a word clicked with Option held.
/// A plain click still places the cursor for editing.
final class WordTextView: NSTextView {
    /// Reached with Tab only. AppKit also walks the key view loop for a window
    /// first shown and when the view with the focus hides, as the library does:
    /// the cursor would land in the text, and the next Space would type there
    /// rather than play.
    override var canBecomeKeyView: Bool {
        let tab: UInt16 = 48  // kVK_Tab
        guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == tab else {
            return false
        }
        return super.canBecomeKeyView
    }

    /// Within a change of this view's size, which may set its size again.
    private var isResizing = false

    override func setFrameSize(_ size: NSSize) {
        let wasResizing = isResizing
        isResizing = true
        defer { isResizing = wasResizing }
        super.setFrameSize(size)
    }

    /// Asked of a text view by AppKit as its size changes, to keep the selection
    /// in view, which it does not document. That is for the paragraph being
    /// edited: another one cut by the foot of the page, resized as the window or
    /// the scroll bar change the text's width, pulled the page up to show a
    /// cursor nobody uses.
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        guard !isResizing || window?.firstResponder === self else { return false }
        return super.scrollToVisible(rect)
    }

    /// Plays from the word at a character index; false when no word is there.
    var playFromCharacter: ((Int) -> Bool)?

    // A text view made in code follows the system's text input settings,
    // all on by default. A typed apostrophe would then differ from the
    // engine's, which Find, Replace All and course corrections look for, and
    // spelling correction would rewrite the names a lecture is full of.
    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        turnOffSubstitutions()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        turnOffSubstitutions()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        turnOffSubstitutions()
    }

    private func turnOffSubstitutions() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextReplacementEnabled = false
    }

    /// Option-click without the mouse: plays from the word at the text cursor.
    /// Play From Cursor sends it along the responder chain, so it reaches the
    /// paragraph being edited.
    @objc func playFromCursor(_ sender: Any?) {
        if playFromCharacter?(selectedRange().location) != true { NSSound.beep() }
    }

    /// A click puts the cursor where the reader wants it: it stays there until
    /// they type, rather than follow playback.
    static var holdsCursor = false

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), let playFromCharacter {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if playFromCharacter(index) { return }
        }
        Self.holdsCursor = true
        // No drag from this view is under way once it is clicked again.
        isDraggingSelection = false
        super.mouseDown(with: event)
    }

    /// Whether the paragraph being edited was hidden with the cursor in it, as
    /// rows far from playback are after a jump. The reader is still editing.
    static var lostCursor = false

    /// The page reads as one text, with one selection, in the paragraph being
    /// edited. A text view keeps its own when it loses the focus, so the one
    /// left drops it here, and so does a row hidden with the cursor in it.
    /// It drops it before AppKit takes the focus away, which hides the cursor:
    /// a change of selection after that shows the cursor again, since the
    /// window still names this view as the one with the focus, which AppKit
    /// does not document, and nothing hides it afterwards. Nothing here
    /// refuses to end editing: a delegate that did would keep the focus with
    /// the selection gone.
    override func resignFirstResponder() -> Bool {
        if !isDraggingSelection { dropSelection() }
        guard super.resignFirstResponder() else { return false }
        if isHiddenOrHasHiddenAncestor { Self.lostCursor = true }
        return true
    }

    /// True while this view drops its selection, which is not the reader
    /// moving the cursor here.
    private(set) var isDroppingSelection = false

    private func dropSelection() {
        // Text being composed, such as an accent waiting for its letter, is
        // AppKit's to end.
        guard selectedRange().length > 0, !hasMarkedText() else { return }
        isDroppingSelection = true
        defer { isDroppingSelection = false }
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
    }

    /// True during a drag of this paragraph's selection. As the drag ends,
    /// AppKit takes text moved to another paragraph, or to the Trash, out of this
    /// one, and only what is still selected here, which it does not document:
    /// the selection stays until then.
    private var isDraggingSelection = false

    override func dragSelection(with event: NSEvent, offset: NSSize, slideBack: Bool) -> Bool {
        isDraggingSelection = true
        let began = super.dragSelection(with: event, offset: offset, slideBack: slideBack)
        if !began { isDraggingSelection = false }
        return began
    }

    override func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        isDraggingSelection = false
        if window?.firstResponder !== self { dropSelection() }
    }

    /// Text dropped here is selected here, so the focus comes with it: a text
    /// view takes a drop without it, and the paragraph the reader was in would
    /// keep a selection of its own.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        window?.makeFirstResponder(self)
        return super.performDragOperation(sender)
    }

    override func becomeFirstResponder() -> Bool {
        Self.lostCursor = false
        return super.becomeFirstResponder()
    }

    /// Takes the cursor to the end of `word`, the one being heard, while the
    /// reader is editing the transcript with nothing selected, into this
    /// paragraph if the word is here.
    func follow(_ word: NSRange) {
        guard word.length > 0, !Self.holdsCursor, let window,
            NSMaxRange(word) <= (string as NSString).length
        else { return }
        if let editing = window.firstResponder as? WordTextView {
            guard editing.selectedRange().length == 0 else { return }
            if editing !== self { window.makeFirstResponder(self) }
        } else {
            guard Self.lostCursor, window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
        setSelectedRange(NSRange(location: NSMaxRange(word), length: 0))
    }

    /// Escape leaves the text, so that Space plays and pauses again.
    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
    }
}
