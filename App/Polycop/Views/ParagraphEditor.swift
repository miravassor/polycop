// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Edits a paragraph with native undo, spelling and selection.
/// Both comparison columns use attributed text to highlight changed words.
struct ParagraphEditor: NSViewRepresentable {
    let text: String
    /// The paragraph as the engine wrote it, to tell corrections apart.
    let original: String
    let size: CGFloat
    let isEditable: Bool
    var isRemoved = false
    let edit: (String) -> Void
    var showsChanges = true
    var matches: [NSRange] = []
    var currentMatch: NSRange?
    var activate: () -> Void = {}
    /// The timed words found in the text, for playing from one and marking
    /// the uncertain ones.
    var words: [WordLayout.Placed] = []
    /// The paragraph's opening second when its words are timed, so that a click
    /// in text written since still plays from about there.
    var timedStart: TimeInterval?
    var playingWord: NSRange?
    var showsUncertainWords = true
    var playFrom: (TimeInterval) -> Void = { _ in }
    /// Called at each key, before the model has the text.
    var typing: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WordTextView {
        // TextKit 1 on purpose: the height of the laid out text, which decides
        // the height of the row, is read from its layout manager.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let view = WordTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.allowsUndo = true
        return view
    }

    func updateNSView(_ view: WordTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        view.isEditable = isEditable
        view.isSelectable = true
        let words = words
        let timedStart = timedStart
        let playFrom = playFrom
        let placedIn = text
        view.playFromCharacter = { [weak view] index in
            guard let view, let timedStart else { return false }
            // The words were placed in the model's text, which does not have
            // yet the typing this click has just handed over.
            let index = WordLayout.index(index, in: view.string, placedIn: placedIn)
            playFrom(WordLayout.time(at: index, in: words, from: timedStart))
            return true
        }
        // While typing, the text view is ahead of the model: nothing here may
        // put the model's older text back, or style the text by stale ranges.
        guard context.coordinator.pending == nil else { return }
        let replacesText = view.string != text
        if replacesText {
            // Native undo ranges belong to the previous text after an external revert.
            view.breakUndoCoalescing()
            context.coordinator.undo.removeAllActions()
            let selected = view.selectedRange()
            view.string = text
            let end = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selected.location, end), length: 0))
        }
        if replacesText || context.coordinator.shownWord != playingWord {
            show(playingWord, in: view)
            context.coordinator.shownWord = playingWord
        }
        guard !view.hasMarkedText() else { return }
        if context.coordinator.revealed != currentMatch {
            context.coordinator.revealed = currentMatch
            if let currentMatch {
                let expected = text
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.string == expected else { return }
                    view.scrollRangeToVisible(currentMatch)
                }
            }
        }
        let signature = Style(
            text: text, original: original, size: size, isRemoved: isRemoved,
            showsChanges: showsChanges, matches: matches, currentMatch: currentMatch,
            uncertain: showsUncertainWords ? words.filter(\.isUncertain).map(\.range) : [])
        guard context.coordinator.styled != signature else { return }
        style(view)
        context.coordinator.styled = signature
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: WordTextView, context: Context
    ) -> CGSize? {
        // Fall back to the current width when SwiftUI leaves it unspecified.
        // AppKit's unbounded intrinsic height would create an endless scroll area.
        let proposed = proposal.width ?? view.bounds.width
        guard proposed > 0, proposed.isFinite,
            let container = view.textContainer, let manager = view.layoutManager
        else { return nil }
        let width = proposed
        container.containerSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = Self.height(of: manager, in: container)
        context.coordinator.height = height
        return CGSize(width: width, height: ceil(max(height, size * 1.5)))
    }

    static func dismantleNSView(_ view: WordTextView, coordinator: Coordinator) {
        coordinator.commit()
    }

    private static func height(of manager: NSLayoutManager, in container: NSTextContainer)
        -> CGFloat
    {
        max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
    }

    /// The word being played, as a temporary attribute of the layout: it moves
    /// several times a second, and restyling the text each time would compare
    /// it with the original again.
    private func show(_ word: NSRange?, in view: NSTextView) {
        guard let manager = view.layoutManager else { return }
        let whole = NSRange(location: 0, length: (view.string as NSString).length)
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        guard let word, NSMaxRange(word) <= whole.length else { return }
        manager.addTemporaryAttribute(
            .backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.18),
            forCharacterRange: word)
    }

    /// Corrections in their own colour, the rest as written.
    private func style(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let whole = NSRange(location: 0, length: (view.string as NSString).length)
        storage.beginEditing()
        storage.setAttributes(
            [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor],
            range: whole)
        let changed = showsChanges ? Edits.changed(from: original, to: view.string) : []
        for range in Edits.ranges(of: changed, in: view.string) {
            let marked = NSRange(range, in: view.string)
            storage.addAttribute(
                .foregroundColor, value: isRemoved ? NSColor.systemRed : NSColor.systemGreen,
                range: marked)
            // Struck through as well on the original side: colour alone does
            // not say which of two words replaced the other.
            if isRemoved {
                storage.addAttributes(
                    [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: NSColor.systemRed,
                    ], range: marked)
            }
        }
        for range in matches where range.location >= 0 && NSMaxRange(range) <= whole.length {
            storage.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.22), range: range)
        }
        if showsUncertainWords {
            for word in words where word.isUncertain && NSMaxRange(word.range) <= whole.length {
                storage.addAttributes(
                    [
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                            | NSUnderlineStyle.patternDot.rawValue,
                        .underlineColor: NSColor.systemOrange,
                        .toolTip: String(localized: "The model was unsure of this word"),
                    ], range: word.range)
            }
        }
        if let currentMatch, currentMatch.location >= 0, NSMaxRange(currentMatch) <= whole.length {
            storage.addAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.30), range: currentMatch)
        }
        storage.endEditing()
        view.typingAttributes = [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor,
        ]
    }

    struct Style: Equatable {
        let text: String
        let original: String
        let size: CGFloat
        let isRemoved: Bool
        let showsChanges: Bool
        let matches: [NSRange]
        let currentMatch: NSRange?
        let uncertain: [NSRange]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ParagraphEditor
        var styled: Style?
        var revealed: NSRange?
        var shownWord: NSRange?
        var updating = false
        let undo = UndoManager()
        /// Typed text the model has not received yet. A key then redraws this
        /// paragraph alone; the model, and the page with it, follow after a
        /// pause or before anything reads the transcript (`TypingBuffer`).
        var pending: String?
        /// The height of the laid out text, last given to SwiftUI.
        var height: CGFloat = 0
        private var commitAfterPause: Task<Void, Never>?

        init(_ parent: ParagraphEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView,
                view.window?.firstResponder === view
            else { return }
            parent.activate()
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard !updating else { return }
            parent.activate()
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            styled = nil
            pending = view.string
            parent.typing()
            fitHeight(of: view)
            TypingBuffer.hold(self)
            commitAfterPause?.cancel()
            commitAfterPause = Task { [weak self] in
                try? await Task.sleep(for: TypingBuffer.pause)
                guard !Task.isCancelled else { return }
                self?.commit()
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            commit()
        }

        /// Hands the typed text to the model.
        func commit() {
            commitAfterPause?.cancel()
            commitAfterPause = nil
            TypingBuffer.release(self)
            guard let text = pending else { return }
            pending = nil
            parent.edit(text)
        }

        /// A new line changes the height of the row. SwiftUI learns it from
        /// the intrinsic size, since the model hears of the text only later.
        private func fitHeight(of view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else {
                return
            }
            manager.ensureLayout(for: container)
            let laidOut = ParagraphEditor.height(of: manager, in: container)
            guard laidOut != height else { return }
            height = laidOut
            view.invalidateIntrinsicContentSize()
        }
    }
}

/// A text view that plays the recording from a word clicked with Option held.
/// A plain click still places the cursor for editing.
final class WordTextView: NSTextView {
    /// Plays from the word at a character index; false when no word is there.
    var playFromCharacter: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), let playFromCharacter {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if playFromCharacter(index) { return }
        }
        super.mouseDown(with: event)
    }

    /// Escape leaves the text, so that Space plays and pauses again.
    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
    }
}

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
