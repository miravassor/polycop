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
    /// The transcript's first correction, which Undo and the library's edited
    /// mark show.
    case firstCorrection
    /// Typing handed to the model, after the first correction of the transcript.
    case handover
    /// Find's Replace All, with its write.
    case replaceAll
    /// The record written once typing stops.
    case write
    /// A key typed in Find, which shows what it finds.
    case findKey
    /// Typing handed to the model while Find shows its results.
    case handoverWhileFinding
    /// A paragraph flagged for review, which the tools count.
    case flag
    /// The transcript renamed, as its row and the window's title say.
    case rename
    /// A warning about the text dismissed, which the inspector lists.
    case dismissWarning
    /// Work starting on another recording, which the warnings' fixes wait for.
    case jobStarts
    /// That work going on.
    case jobProgress
    /// That work ending.
    case jobEnds
}

/// What each change redraws of the structure. A change that reaches a piece
/// not listed fails, and so does one that no longer reaches a piece listed,
/// which would leave that piece showing what was: a change of the text alone
/// reaches none, a change of what the structure shows the pieces that show it.
private let mayRedraw: [Change: Set<Redraws.Piece>] = [
    .key: [],
    .pointer: [],
    .wordHeard: [],
    .click: [],
    .firstCorrection: [.library, .page, .tools],
    .handover: [],
    .replaceAll: [],
    .write: [],
    .findKey: [],
    .handoverWhileFinding: [],
    .flag: [.page, .tools],
    .rename: [.library, .page],
    .dismissWarning: [.page, .inspector],
    .jobStarts: [.page, .inspector],
    .jobProgress: [],
    .jobEnds: [.page, .inspector],
]

/// Each change redraws exactly the pieces listed for it. Before any is
/// counted, each piece redrawn alone redraws none of the pieces it holds.
@MainActor
@Test func eachChangeOnThePageRedrawsOnlyTheStructureListedForIt() async throws {
    try await withHostedPage(lecture()) { page in
        try await openCounting(page)
        try await settle(page)
        var redrew = try await corrections(on: page)
        redrew.merge(try await shownFacts(on: page)) { $1 }
        redrew.merge(try await editing(on: page)) { $1 }
        redrew.merge(try await listening(on: page)) { $1 }
        redrew.merge(try await finding(on: page)) { $1 }
        for change in Change.allCases {
            #expect(redrew[change] == mayRedraw[change], "\(change)")
        }
    }
}

/// Opens the page, each piece running as it does: a count lost in a change of
/// the code fails here rather than counting nothing. The inspector's body runs
/// whether its column shows or is folded, so its count is what says it is
/// counted, not the column.
@MainActor
private func openCounting(_ page: HostedPage) async throws {
    let closed = Redraws.counts(in: page.model)
    try await page.open()
    let opened = Redraws.counts(in: page.model)
    for piece in Redraws.Piece.allCases {
        #expect(opened[piece, default: 0] > closed[piece, default: 0], "\(piece) never ran")
    }
}

/// Waits until SwiftUI skips a piece given what it was given before, which
/// every change below relies on. Observed, not documented: soon after a view
/// appears, and for longer on a busy Mac, SwiftUI can take values equal to the
/// last for new ones and run the body; those runs stop with AttributeGraph's
/// private `AG_ASYNC_LAYOUTS=0`. So each piece is redrawn alone until none of
/// those it holds is redrawn with it.
@MainActor
private func settle(_ page: HostedPage) async throws {
    var unsettled = try await unsettledPieces(of: page)
    for _ in 0..<100 where !unsettled.isEmpty {
        try await Task.sleep(for: .milliseconds(50))
        unsettled = try await unsettledPieces(of: page)
    }
    try #require(
        unsettled.isEmpty,
        """
        Redrawn alone, a piece redrew others: \(unsettled). Either SwiftUI has not \
        settled, or a piece is given something new at each run, such as a closure.
        """)
}

/// The pieces that redrew others when redrawn alone, with what they redrew.
@MainActor
private func unsettledPieces(of page: HostedPage) async throws
    -> [Redraws.Piece: Set<Redraws.Piece>]
{
    var unsettled: [Redraws.Piece: Set<Redraws.Piece>] = [:]
    for piece in Redraws.Piece.allCases {
        let redrew = try await redrawn(in: page.model) { Redraws.redraw(piece, in: page.model) }
        if redrew != [piece] { unsettled[piece] = redrew }
    }
    return unsettled
}

/// The first correction, a later one, its write, then Replace All.
@MainActor
private func corrections(on page: HostedPage) async throws -> [Change: Set<Redraws.Piece>] {
    let (model, id) = (page.model, page.id)
    var redrew: [Change: Set<Redraws.Piece>] = [:]
    let first = try #require(model.entry(id)?.paragraphs[0].text)
    redrew[.firstCorrection] = try await redrawn(
        in: model, drawn: { page.shown.contains(first + " ?") }
    ) {
        model.edit(id, paragraphAt: 0, text: first + " ?")
    }
    model.savePending()
    await model.finishWrites()
    await turns(2)

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

/// Changes of what the page's structure shows: a flag, a new name, a warning
/// dismissed, and work on another recording starting, going on and ending.
@MainActor
private func shownFacts(on page: HostedPage) async throws -> [Change: Set<Redraws.Piece>] {
    let (model, id) = (page.model, page.id)
    var redrew: [Change: Set<Redraws.Piece>] = [:]
    redrew[.flag] = try await redrawn(in: model) { model.toggleReview(id, paragraphAt: 1) }
    redrew[.rename] = try await redrawn(in: model) { model.rename(id, to: "Cours renommé") }
    redrew[.dismissWarning] = try await redrawn(in: model) {
        model.setDismissed([.resumed], true, on: id)
    }
    await model.finishWrites()
    // The stage a job sets, with no recording to transcribe behind it.
    redrew[.jobStarts] = try await redrawn(in: model) { model.stage = .transcribing(0.1) }
    redrew[.jobProgress] = try await redrawn(in: model) { model.stage = .transcribing(0.2) }
    redrew[.jobEnds] = try await redrawn(in: model) { model.stage = .waiting }
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

    let heard = try page.textView(of: 0)
    let word = heardWord(in: heard)
    redrew[.wordHeard] = try await redrawn(in: model, drawn: { heardWord(in: heard) != word }) {
        player.seek(to: 0.6)
    }

    let pointer = try #require(Redraws.pointer(of: model))
    pointer.point(at: 2)
    await turns(2)
    let greys = Redraws.greys(of: pointer)
    redrew[.pointer] = try await redrawn(in: model, drawn: { Redraws.greys(of: pointer) > greys }) {
        pointer.point(at: 3)
    }
    return redrew
}

/// Find opened on a word, as its button and its field do, then a key typed in
/// it, and a correction handed over that moves the results it shows.
@MainActor
private func finding(on page: HostedPage) async throws -> [Change: Set<Redraws.Piece>] {
    let (model, id) = (page.model, page.id)
    let find = try #require(Redraws.find(of: model))
    let text = try #require(model.entry(id)?.paragraphs[0].text)
    func firstResult() -> Int? {
        page.textViews.first { $0.string == text }.flatMap(results(in:))?.first?.length
    }
    find.isShown = true
    find.query = "conce"
    for _ in 0..<20 where firstResult() != 5 { await turns(1) }
    try #require(firstResult() == 5, "Find shows no result")
    try await settle(page)
    var redrew: [Change: Set<Redraws.Piece>] = [:]

    redrew[.findKey] = try await redrawn(in: model, drawn: { firstResult() == 7 }) {
        find.query = "concept"
    }

    let corrected = "Bien." + text
    redrew[.handoverWhileFinding] = try await redrawn(
        in: model, drawn: { page.shown.contains(corrected) }
    ) {
        model.edit(id, paragraphAt: 0, text: corrected)
    }
    model.savePending()
    await model.finishWrites()
    return redrew
}

/// The stretches a paragraph's text view marks as results of Find, with a
/// background in its text.
@MainActor
private func results(in view: WordTextView) -> [NSRange]? {
    guard let storage = view.textStorage else { return nil }
    var marked: [NSRange] = []
    storage.enumerateAttribute(
        .backgroundColor, in: NSRange(location: 0, length: storage.length)
    ) { value, range, _ in
        if value != nil { marked.append(range) }
    }
    return marked
}

/// The word a paragraph's text view shows as heard: the stretch its editor
/// marks with a background of the layout manager's own.
@MainActor
private func heardWord(in view: WordTextView) -> NSRange? {
    guard let manager = view.layoutManager else { return nil }
    let length = (view.string as NSString).length
    var index = 0
    while index < length {
        var stretch = NSRange()
        if manager.temporaryAttribute(
            .backgroundColor, atCharacterIndex: index, effectiveRange: &stretch) != nil
        {
            return stretch
        }
        index = max(NSMaxRange(stretch), index + 1)
    }
    return nil
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
/// be inside the clip the player opens, resumed once, which the warnings say.
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
    entry.resumedAt = [1.0]
    return entry
}
