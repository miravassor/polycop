// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Polycop

/// Hosts `EntryFindBar` with its own state and focus binding so that
/// `NSHostingController` lays out and updates it as the transcript page does.
private struct HostedFindBar: View {
    let model: AppModel
    let entry: Entry
    let isRunning: Bool
    @State var find: TranscriptFind
    @FocusState private var isFocused: Bool

    var body: some View {
        EntryFindBar(
            model: model, entry: entry, isRunning: isRunning, find: $find,
            isFocused: $isFocused, navigate: { find.step(forward: $0) })
    }
}

@MainActor
private func host(
    _ find: TranscriptFind, model: AppModel, entry: Entry, isRunning: Bool = false
) -> NSHostingController<HostedFindBar> {
    let controller = NSHostingController(
        rootView: HostedFindBar(model: model, entry: entry, isRunning: isRunning, find: find))
    let size = controller.sizeThatFits(in: CGSize(width: 560, height: CGFloat.infinity))
    controller.view.frame = NSRect(origin: .zero, size: size)
    controller.view.layoutSubtreeIfNeeded()
    return controller
}

@MainActor
private func textFields(in view: NSView) -> [NSTextField] {
    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields(in:))
}

@MainActor
@Test func findBarRendersFindAndReplaceRowsInHostingController() {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = AppModel(
        history: folder.appending(path: "History"),
        glossaries: folder.appending(path: "Glossaries"),
        defaults: MemoryDefaults())
    let entry = Entry(
        recording: folder.appending(path: "lecture.wav"),
        modelFile: ModelCatalog.recommended.id,
        glossary: Glossary(name: "Philosophie", text: ""),
        skipsSilence: false, subtitles: false)
    let matches = [
        TranscriptSearch.Match(paragraph: 0, range: NSRange(location: 0, length: 5)),
        TranscriptSearch.Match(paragraph: 1, range: NSRange(location: 8, length: 5)),
    ]

    let findOnly = host(
        TranscriptFind(isShown: true, query: "Freud", matches: matches),
        model: model, entry: entry)
    #expect(findOnly.view.frame.height > 0)
    #expect(textFields(in: findOnly.view).map(\.placeholderString) == ["Find in your text"])
    #expect(textFields(in: findOnly.view).map(\.stringValue) == ["Freud"])

    let withoutMatches = host(
        TranscriptFind(isShown: true, query: "absent", matches: []),
        model: model, entry: entry)
    #expect(withoutMatches.view.frame.height > 0)
    #expect(textFields(in: withoutMatches.view).map(\.stringValue) == ["absent"])

    let replacing = host(
        TranscriptFind(
            isShown: true, query: "Freud", matches: matches,
            isReplacing: true, replacement: "Froid"),
        model: model, entry: entry)
    #expect(replacing.view.frame.height > findOnly.view.frame.height)
    #expect(
        textFields(in: replacing.view).map(\.placeholderString) == [
            "Find in your text", "Replace with",
        ])
    #expect(textFields(in: replacing.view).map(\.stringValue) == ["Freud", "Froid"])

    let replacingWithoutMatches = host(
        TranscriptFind(isShown: true, query: "absent", matches: [], isReplacing: true),
        model: model, entry: entry, isRunning: true)
    #expect(replacingWithoutMatches.view.frame.height > withoutMatches.view.frame.height)
    #expect(textFields(in: replacingWithoutMatches.view).count == 2)
}

@MainActor
@Test func transcriptFindNavigatesBoundariesAndWaitsAfterAnEdit() {
    var paragraphs = [
        Transcript.Paragraph(start: 0, text: "mot un, mot deux"),
        Transcript.Paragraph(start: 30_000, text: "mot trois"),
    ]
    var find = TranscriptFind(isShown: true, query: "mot")
    find.refresh(in: paragraphs, startingOver: true)
    #expect(find.matches.count == 3)
    #expect(find.index == 0)
    #expect(find.current == find.matches[0])

    // Stepping backward at the start wraps to the last match; forward wraps back.
    find.step(forward: false)
    #expect(find.index == 2)
    #expect(find.current == find.matches[2])
    find.step(forward: true)
    #expect(find.index == 0)
    #expect(find.current == find.matches[0])

    // When an edit removes the current match, the match waiting at that place is
    // not shown until the next forward step, while a backward step moves before it.
    paragraphs[0].text = "un, mot deux"
    find.refresh(in: paragraphs, startingOver: false)
    #expect(find.matches.count == 2)
    #expect(find.index == 0)
    #expect(!find.showsCurrent)
    #expect(find.current == nil)

    find.step(forward: true)
    #expect(find.index == 0)
    #expect(find.showsCurrent)
    #expect(find.current == find.matches[0])

    find.step(forward: true)
    #expect(find.index == 1)
    paragraphs[1].text = "trois"
    find.refresh(in: paragraphs, startingOver: false)
    #expect(find.matches.count == 1)
    #expect(find.index == 0)
    #expect(!find.showsCurrent)
    #expect(find.current == nil)

    find.step(forward: false)
    #expect(find.index == 0)
    #expect(find.showsCurrent)
    #expect(find.current == find.matches[0])
}
