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
