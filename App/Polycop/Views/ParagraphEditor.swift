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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
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
        let view = NSTextView(frame: .zero, textContainer: container)
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

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        view.isEditable = isEditable
        view.isSelectable = true
        if view.string != text {
            // Native undo ranges belong to the previous text after an external revert.
            view.breakUndoCoalescing()
            context.coordinator.undo.removeAllActions()
            let selected = view.selectedRange()
            view.string = text
            let end = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selected.location, end), length: 0))
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
            showsChanges: showsChanges, matches: matches, currentMatch: currentMatch)
        guard context.coordinator.styled != signature else { return }
        style(view)
        context.coordinator.styled = signature
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: NSTextView, context: Context
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
        let height = max(
            manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        return CGSize(width: width, height: ceil(max(height, size * 1.5)))
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
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ParagraphEditor
        var styled: Style?
        var revealed: NSRange?
        var updating = false
        let undo = UndoManager()

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
            parent.edit(view.string)
        }
    }
}
