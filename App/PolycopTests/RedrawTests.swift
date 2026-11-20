// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Testing

@testable import Polycop

// What each change on the page of a lecture redraws of the window's
// structure: the views that declare the split view, the toolbar and the
// inspector, counted in bodies run (`Redraws`) by the window's own model, so
// that the pages other tests host meanwhile add nothing.

/// A change a reader makes on the page, or that playback makes.
private enum Change: CaseIterable {
    /// A key typed in a paragraph, which stays in its text view for a while.
    case key
    /// The pointer moving onto another paragraph, in the text or on the timeline.
    case pointer
    /// Playback reaching another word of the same paragraph.
    case wordHeard
    /// A click into another paragraph than the one being edited.
    case click
    /// Typing handed to the model, after the first correction of the transcript.
    case handover
    /// Find's Replace All, with its write.
    case replaceAll
    /// The record written once typing stops.
    case write
}

/// What each change may redraw of the structure today. A change that reaches
/// a piece not listed fails, and so does one that no longer reaches a piece
/// listed: whatever keeps it from that piece takes the piece off this list.
private let mayRedraw: [Change: Set<Redraws.Piece>] = [
    .key: [],
    .pointer: [],
    .wordHeard: [],
    .click: [.page, .tools],
    .handover: [.window, .page, .inspector],
    .replaceAll: [.window, .page, .inspector],
    .write: [.page],
]

@MainActor
@Test func eachChangeOnThePageRedrawsOnlyTheStructureListedForIt() async throws {
    try await withHostedPage(lecture()) { page in
        try await openCounting(page)
        var redrew = try await corrections(on: page)
        redrew.merge(try await editing(on: page)) { $1 }
        redrew.merge(try await listening(on: page)) { $1 }
        for change in Change.allCases {
            #expect(redrew[change] == mayRedraw[change], "\(change)")
        }
    }
}

/// Opens the page, each piece running as it does, with the inspector shown:
/// a count lost in a change of the code, or an inspector folded, fails here
/// rather than counting nothing.
@MainActor
private func openCounting(_ page: HostedPage) async throws {
    let closed = Redraws.counts(in: page.model)
    try await page.open()
    let opened = Redraws.counts(in: page.model)
    #expect(page.model.layout.showsInspector)
    for piece in Redraws.Piece.allCases {
        #expect(opened[piece, default: 0] > closed[piece, default: 0], "\(piece) never ran")
    }
}

/// A handover, its write, then Replace All. The first correction changes what
/// the tools show, Undo among them: those counted come after it, as most do.
@MainActor
private func corrections(on page: HostedPage) async throws -> [Change: Set<Redraws.Piece>] {
    let (model, id) = (page.model, page.id)
    let first = try #require(model.entry(id)?.paragraphs[0].text)
    model.edit(id, paragraphAt: 0, text: first + " ?")
    model.savePending()
    await model.finishWrites()
    await turns(2)
    var redrew: [Change: Set<Redraws.Piece>] = [:]

    let third = try #require(model.entry(id)?.paragraphs[2].text)
    let corrected = String(third.dropLast()) + "?"
    redrew[.handover] = try await redrawn(in: model, drawn: { page.shown.contains(corrected) }) {
        model.edit(id, paragraphAt: 2, text: corrected)
    }

    // The handover's own write waits for a pause, which a slow machine can let
    // pass inside the step above: written now, wherever it fell, so that no
    // step below meets it, and the write timed is one that surely happens.
    model.savePending()
    await model.finishWrites()
    await turns(2)

    let record = try #require(model.entry(id))
    redrew[.write] = try await redrawn(in: model) {
        model.store(record)
        await model.finishWrites()
    }

    let paragraphs = try #require(model.entry(id)?.paragraphs)
    let matches = TranscriptSearch.matches(in: paragraphs, query: "concept").filter {
        $0.paragraph == 3
    }
    try #require(!matches.isEmpty)
    func showsReplaced() -> Bool {
        model.entry(id).map { page.shown.contains($0.paragraphs[3].text) } ?? false
    }
    redrew[.replaceAll] = try await redrawn(in: model, drawn: showsReplaced) {
        model.replace(id, matches: matches, with: "notion")
        await model.finishWrites()
    }
    return redrew
}

/// A click into another paragraph than the one being edited, then a key there.
@MainActor
private func editing(on page: HostedPage) async throws -> [Change: Set<Redraws.Piece>] {
    let model = page.model
    let edited = try page.textView(of: 1)
    page.window.makeFirstResponder(edited)
    edited.setSelectedRange(NSRange(location: 5, length: 0))
    await turns(2)
    var redrew: [Change: Set<Redraws.Piece>] = [:]

    let clicked = try page.textView(of: 4)
    redrew[.click] = try await redrawn(in: model) {
        page.window.makeFirstResponder(clicked)
        clicked.setSelectedRange(NSRange(location: 5, length: 0))
    }

    let editor = try #require(clicked.delegate as? ParagraphEditor.Coordinator)
    let untyped = clicked.string
    redrew[.key] = try await redrawn(in: model, drawn: { clicked.string != untyped }) {
        clicked.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        // Out of the buffer every window shares, its pause put off: no other
        // test's handover, nor the pause, hands this key over while it is
        // counted.
        editor.commitAfterPause?.cancel()
        TypingBuffer.release(editor)
    }
    editor.commit()
    model.savePending()
    await model.finishWrites()
    await turns(2)
    return redrew
}

/// A word heard, the recording open and paused, then the pointer onto another
/// paragraph.
@MainActor
private func listening(on page: HostedPage) async throws -> [Change: Set<Redraws.Piece>] {
    let (model, player) = (page.model, page.model.player)
    model.replay(page.id, from: 0.3, leadIn: 0)
    for _ in 0..<100 where !player.isOpen || player.isPreparing {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(player.isOpen)
    if player.isPlaying { player.toggle() }
    await turns(2)
    var redrew: [Change: Set<Redraws.Piece>] = [:]

    redrew[.wordHeard] = try await redrawn(in: model, drawn: { player.position == 0.6 }) {
        player.seek(to: 0.6)
    }

    let pointer = try #require(Redraws.pointer(of: model))
    pointer.point(at: 2)
    await turns(2)
    redrew[.pointer] = try await redrawn(in: model, drawn: { pointer.paragraph == 3 }) {
        pointer.point(at: 3)
    }
    return redrew
}

/// The pieces whose body ran for `change`: from the change until the page
/// has drawn it, polled over a bound of run loop turns, then two turns more
/// for what the drawing set off.
@MainActor
private func redrawn(
    in model: AppModel, drawn: () -> Bool = { true }, by change: () async throws -> Void
) async throws -> Set<Redraws.Piece> {
    let before = Redraws.counts(in: model)
    try await change()
    for _ in 0..<20 where !drawn() { await turns(1) }
    try #require(drawn(), "the page did not draw the change")
    await turns(2)
    let after = Redraws.counts(in: model)
    return Set(Redraws.Piece.allCases.filter { after[$0, default: 0] > before[$0, default: 0] })
}

/// A lecture of 300 paragraphs, of words short enough for the first ones to
/// be inside the clip the player opens.
@MainActor
private func lecture() -> Entry {
    let vocabulary = [
        "Le", "concept", "de", "psychopathologie", "désigne", "l'étude", "des", "troubles",
        "mentaux,", "de", "leurs", "causes", "et", "de", "leurs", "mécanismes.",
    ]
    var segments: [Segment] = []
    var time = 0.0
    for index in 0..<600 {
        var words: [Segment.Word] = []
        for offset in 0..<18 {
            let spoken = vocabulary[(index + offset) % vocabulary.count]
            words.append(.init(text: spoken, start: time, end: time + 0.05, confidence: 0.9))
            time += 0.06
        }
        let text = words.map { " " + $0.text }.joined()
        segments.append(Segment(start: words[0].start, end: time, text: text, words: words))
        // A silence after every second segment, so that two make a paragraph.
        if index % 2 == 1 { time += 2 }
    }
    var entry = Entry(
        recording: HostedPage.clipFR, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.publish(segments, partial: false)
    entry.state = .finished
    return entry
}
