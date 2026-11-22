// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Polycop

@MainActor
private func textViews(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
}

@MainActor
private func waitForTextView(
    in view: NSView, matching expected: String
) async throws -> NSTextView {
    for _ in 0..<500 {
        if let editor = textViews(in: view).first, editor.string == expected {
            return editor
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let editor = try #require(
        textViews(in: view).first, "the glossary editor showed no text view")
    #expect(editor.string == expected)
    return editor
}

/// Hosts `GlossaryEditor` in a transparent, non-key window backed by an
/// isolated temporary folder and in-memory settings, closing and shutting down
/// whatever happens inside.
@MainActor
private func withGlossaryEditor(
    glossaries initial: [Glossary] = [],
    selected: String? = nil,
    _ body: (URL, NSHostingController<GlossaryEditor>) async throws -> Void
) async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let glossaries = folder.appending(path: "Glossaries")
    for glossary in initial {
        try GlossaryStore.save(glossary, in: glossaries)
    }
    let model = AppModel(
        history: folder.appending(path: "History"),
        glossaries: glossaries,
        models: folder.appending(path: "Models"),
        playbackCopies: folder.appending(path: "Copies"),
        defaults: MemoryDefaults())
    model.glossaryName = selected
    let controller = NSHostingController(rootView: GlossaryEditor(model: model))
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: GlossaryEditor.sheetSize),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.contentViewController = controller
    window.orderFront(nil)
    do {
        try await body(glossaries, controller)
    } catch {
        window.close()
        await model.shutDown()
        throw error
    }
    window.close()
    await model.shutDown()
}

/// The sheet fits inside the smallest window and shows no terms editor when the
/// library has no courses.
@MainActor
@Test func glossaryEditorFitsInsideSmallestWindowWhenEmpty() async throws {
    try await withGlossaryEditor { _, controller in
        await turns(2)
        let size = controller.view.fittingSize
        #expect(size == GlossaryEditor.sheetSize)
        // ContentView's minimum window size is 860 by 600.
        #expect(size.width <= 860)
        #expect(size.height <= 600)
        #expect(textViews(in: controller.view).isEmpty)
    }
}

/// Opening the sheet selects the model's current course, loads its terms, and
/// saves edits typed in the editor without disturbing other courses.
@MainActor
@Test func glossaryEditorOpensSelectedCourseAndSavesEdits() async throws {
    let courses = [
        Glossary(name: "Anatomie", text: "cortex\ncervelet"),
        Glossary(name: "Philosophie", text: "Descartes\nPascal"),
    ]
    try await withGlossaryEditor(glossaries: courses, selected: "Philosophie") {
        glossaries, controller in
        let editor = try await waitForTextView(
            in: controller.view, matching: "Descartes\nPascal")
        #expect(controller.view.fittingSize == GlossaryEditor.sheetSize)

        let end = (editor.string as NSString).length
        editor.insertText("\nSpinoza", replacementRange: NSRange(location: end, length: 0))

        var saved: [Glossary] = []
        for _ in 0..<500 {
            saved = GlossaryStore.all(in: glossaries).glossaries
            if saved.first(where: { $0.name == "Philosophie" })?.text
                == "Descartes\nPascal\nSpinoza"
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            saved.first(where: { $0.name == "Philosophie" })?.text
                == "Descartes\nPascal\nSpinoza")
        #expect(saved.first(where: { $0.name == "Anatomie" })?.text == "cortex\ncervelet")
    }
}

/// When no glossary is active on the model, the sheet selects the first course
/// alphabetically.
@MainActor
@Test func glossaryEditorSelectsFirstCourseWhenNoneIsChosen() async throws {
    let courses = [
        Glossary(name: "Philosophie", text: "Descartes"),
        Glossary(name: "Anatomie", text: "cortex"),
    ]
    try await withGlossaryEditor(glossaries: courses) { _, controller in
        let editor = try await waitForTextView(in: controller.view, matching: "cortex")
        #expect(editor.string == "cortex")
    }
}

/// Appending terms from the finder skips terms already present regardless of
/// case, keeps the finder's order at the end, and returns `nil` when nothing is
/// new so untouched text is not rewritten.
@Test func appendingTermsDeduplicatesIgnoringCaseAndPreservesOrder() {
    #expect(
        GlossaryEditor.appending(
            ["descartes", "Spinoza", "Leibniz", "PASCAL"], to: "Descartes\nPascal")
            == "Descartes\nPascal\nSpinoza\nLeibniz")
    #expect(
        GlossaryEditor.appending(["descartes", "PASCAL"], to: "Descartes\nPascal") == nil)
    #expect(GlossaryEditor.appending(["Spinoza", "Leibniz"], to: "") == "Spinoza\nLeibniz")
}
