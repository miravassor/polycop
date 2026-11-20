// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing

@testable import Polycop

// Each correction a reader makes, and each change an engine makes, on the
// page hosted as the app shows it: after each, the page shows what the record
// holds, paragraph by paragraph.

/// A transcript of eight paragraphs, all shown at once, each different; with
/// `credits`, a line of credits before them, hidden until it is put back.
@MainActor
private func lesson(after credits: Bool = false) -> Entry {
    var segments: [Segment] = []
    if credits {
        segments.append(Segment(start: 0, end: 2, text: " Sous-titrage Société Radio-Canada"))
    }
    for index in 0..<8 {
        let start = Double(index) * 3 + (credits ? 4 : 0)
        segments.append(
            Segment(
                start: start, end: start + 1.2,
                text: " Paragraphe \(index + 1), le concept et ses causes."))
    }
    var entry = Entry(
        recording: HostedPage.clipFR, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.publish(segments, partial: false)
    entry.state = .finished
    return entry
}

/// What the page shows of each paragraph is what the record holds, once the
/// page has drawn the change. A busy machine can delay the drawing, so the
/// page is given a few seconds unless `bound` says otherwise.
@MainActor
private func expectInStep(
    _ page: HostedPage, within bound: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    await turns(2)
    let deadline = ContinuousClock.now + bound
    while page.shown != page.held, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(page.shown == page.held, sourceLocation: sourceLocation)
}

@MainActor
@Test func typedTextAndItsUndoShowWhatTheRecordHolds() async throws {
    try await withHostedPage(lesson()) { page in
        try await page.open()
        let before = try #require(page.entry?.paragraphs[2].text)

        try page.type(" fin", inParagraph: 2)
        page.handOver()
        #expect(page.entry?.paragraphs[2].text == before + " fin")
        try await expectInStep(page)

        // A burst of typing is one step back.
        page.model.undo(page.id)
        #expect(page.entry?.paragraphs[2].text == before)
        #expect(!page.model.canUndo(page.id))
        try await expectInStep(page)
    }
}

@MainActor
@Test func replaceAllAndItsUndoShowWhatTheRecordHolds() async throws {
    try await withHostedPage(lesson()) { page in
        try await page.open()
        let before = try #require(page.entry?.paragraphs)

        page.model.replace(
            page.id, matches: TranscriptSearch.matches(in: before, query: "concept"),
            with: "principe")
        #expect(page.entry?.paragraphs.allSatisfy { $0.text.contains("principe") } == true)
        try await expectInStep(page)

        page.model.undo(page.id)
        #expect(page.entry?.paragraphs == before)
        try await expectInStep(page)
    }
}

@MainActor
@Test func revertAndItsUndoShowWhatTheRecordHolds() async throws {
    try await withHostedPage(lesson()) { page in
        try await page.open()
        let before = try #require(page.entry?.paragraphs)

        try page.type(" corrigé", inParagraph: 1)
        page.handOver()
        // A menu's action comes after the page drew the handover.
        await turns(2)
        let corrected = try #require(page.entry?.paragraphs)
        page.model.revert(page.id)
        #expect(page.entry?.paragraphs == before)
        try await expectInStep(page)

        page.model.undo(page.id)
        #expect(page.entry?.paragraphs == corrected)
        try await expectInStep(page)
    }
}

/// A revert in the same turn as the handover leaves the typing on screen: the
/// row is compared by its paragraph, which comes back to the text it last
/// drew, so its text view is not given the record's text again. In the app a
/// menu or a dialog comes between the two, and the page draws the handover
/// first.
@MainActor
@Test func aRevertInTheTurnOfTheHandoverShowsWhatTheRecordHolds() async throws {
    try await withHostedPage(lesson()) { page in
        try await page.open()
        try page.type(" corrigé", inParagraph: 1)
        page.handOver()
        page.model.revert(page.id)
        // The page has drawn the revert in the turns the check waits for, and
        // the typing stays however long it waits after: half a second.
        await withKnownIssue("The typing stays on screen, the record holds the original") {
            try await expectInStep(page, within: .milliseconds(500))
        }
    }
}

@MainActor
@Test func creditsPutBackShowWhatTheRecordHolds() async throws {
    try await withHostedPage(lesson(after: true)) { page in
        try await page.open()
        let count = try #require(page.entry?.paragraphs.count)
        try await expectInStep(page)

        page.model.putBackCredits(page.id)
        #expect(page.entry?.paragraphs.count == count + 1)
        try await expectInStep(page)

        // Nothing to step back: the layout changed under the corrections.
        page.model.undo(page.id)
        #expect(page.entry?.paragraphs.count == count + 1)
        try await expectInStep(page)
    }
}

@MainActor
@Test func aRepairOfTheRepeatsShowsWhatTheRecordHolds() async throws {
    var entry = Entry(
        recording: HostedPage.clipFR, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    let loop = (0..<12).map {
        Segment(start: Double($0) * 0.25, end: Double($0 + 1) * 0.25, text: "Merci.")
    }
    entry.publish(loop + [Segment(start: 3, end: 3.5, text: "La fin du cours.")], partial: false)
    entry.state = .finished
    try await withHostedPage(entry, engines: Opener(ScriptedEngine()).engines) { page in
        try await page.open()
        try await expectInStep(page)
        let before = try #require(page.entry?.paragraphs)

        page.model.repairRepeats(page.id)
        for _ in 0..<200 where page.model.stage.isBusy || page.model.repairing != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(page.entry?.paragraphs != before)
        try await expectInStep(page)

        page.model.undo(page.id)
        try await expectInStep(page)
    }
}

@MainActor
@Test func aTranscriptBeingWrittenShowsWhatTheRecordHolds() async throws {
    let waiting = Entry(
        recording: HostedPage.clipFR, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    let engine = ScriptedEngine(holdsAt: 1)
    try await withHostedPage(waiting, engines: Opener(engine).engines) { page in
        try await page.open()
        page.model.start()
        for _ in 0..<200 where !engine.isHolding {
            try await Task.sleep(for: .milliseconds(50))
        }
        page.model.pause()
        for _ in 0..<200 where !page.model.stage.isPaused {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(page.entry?.paragraphs.count == 1)
        try await expectInStep(page)

        page.model.resume()
        for _ in 0..<200 where page.model.hasWork || page.model.stage.isBusy {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(page.entry?.state == .finished)
        #expect(page.entry?.paragraphs.first?.text.hasSuffix("Voici le plan.") == true)
        try await expectInStep(page)
    }
}

/// Quitting right after a key, as the app delegate does, writes the key.
@MainActor
@Test func aKeyTypedJustBeforeQuittingIsOnDisk() async throws {
    try await withHostedPage(lesson()) { page in
        try await page.open()
        try page.type(" fin", inParagraph: 3)
        page.handOver()
        page.model.rememberPlace(in: page.model.pane)
        await page.model.shutDown()

        let file = page.model.history.appending(path: "\(page.id.uuidString).json")
        let written = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
        #expect(written.paragraphs[3].text.hasSuffix(" fin"))
        #expect(written.paragraphs == page.entry?.paragraphs)
        try await expectInStep(page)
    }
}

/// A key left alone reaches the disk on its own, after the pause that hands
/// it to the model and the one that writes it.
@MainActor
@Test func aKeyLeftAloneReachesTheDisk() async throws {
    try await withHostedPage(lesson()) { page in
        try await page.open()
        let file = page.model.history.appending(path: "\(page.id.uuidString).json")
        func written() throws -> String {
            try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file)).paragraphs[4].text
        }

        try page.type("x", inParagraph: 4)
        for _ in 0..<200 where try !written().hasSuffix("x") {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try written().hasSuffix("x"))
        try await expectInStep(page)
    }
}
