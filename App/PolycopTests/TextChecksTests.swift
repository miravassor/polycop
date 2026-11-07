// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// A finished transcript in a folder of its own, its recording there.
@MainActor
private struct Page {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let model: AppModel

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model = AppModel(history: folder.appending(path: "History"))
    }

    func checks(
        isRunning: Bool = false, _ change: (inout Entry) -> Void = { _ in }
    ) -> TextChecks {
        var entry = Entry(
            recording: folder.appending(path: "lecture.wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        entry.state = .finished
        change(&entry)
        return TextChecks(
            entry: entry, findings: entry.findings,
            canRebuild: model.canRebuildParagraphs(of: entry), model: model, isRunning: isRunning,
            engine: nil)
    }

    func clear() { try? FileManager.default.removeItem(at: folder) }
}

@MainActor
@Suite struct TextChecksOfATranscript {
    @Test func aCleanTranscriptHasNone() throws {
        let page = try Page()
        defer { page.clear() }
        #expect(page.checks().all.isEmpty)
    }

    /// Each keeps its own symbol, and a resumed point can be listened to.
    @Test func eachSaysWhatItIsAndWhereToListen() throws {
        let page = try Page()
        defer { page.clear() }
        let checks = page.checks {
            $0.glossaryWarning = "The glossary could not be read."
            $0.resumedAt = [612, 1840]
        }.all
        #expect(checks.map(\.symbol) == ["exclamationmark.triangle", "arrow.clockwise"])
        #expect(checks[0].text == "The glossary could not be read.")
        #expect(checks[1].times.map(\.title) == ["00:10:12", "00:30:40"])
    }

    /// The list identifies them by their text, so none may be lost to another.
    @Test func noTwoShareAnIdentity() throws {
        let page = try Page()
        defer { page.clear() }
        let checks = page.checks {
            $0.glossaryWarning = "The glossary could not be read."
            $0.resumedAt = [612]
            $0.duration = 600
            $0.decoded = [Segment(start: 0, end: 10, text: "Bonjour à tous.")]
        }.all
        #expect(checks.count == 3)
        #expect(Set(checks.map(\.id)).count == checks.count)
    }

    /// A dismissed warning leaves the text, stays in the inspector, and comes back.
    @Test func aDismissedCheckLeavesTheTextOnly() throws {
        let page = try Page()
        defer { page.clear() }
        let warned: (inout Entry) -> Void = {
            $0.glossaryWarning = "The glossary could not be read."
            $0.resumedAt = [612]
        }
        let dismissed: (inout Entry) -> Void = {
            warned(&$0)
            $0.setDismissed(.resumed, true)
        }
        #expect(page.checks(dismissed).aboveText.map(\.warning) == [.glossary])
        #expect(page.checks(dismissed).all.map(\.warning) == [.glossary, .resumed])
        #expect(page.checks(dismissed).all.map(\.isDismissed) == [false, true])
        let back = page.checks {
            dismissed(&$0)
            $0.setDismissed(.resumed, false)
        }
        #expect(back.aboveText.map(\.warning) == [.glossary, .resumed])
    }

    /// Its text is about to replace what the warning was about.
    @Test func aRunningTranscriptKeepsItsWarnings() throws {
        let page = try Page()
        defer { page.clear() }
        let checks = page.checks(isRunning: true) {
            $0.glossaryWarning = "The glossary could not be read."
        }
        #expect(checks.all.map(\.canChangeDismissal) == [false])
    }
}

/// What the library keeps of a dismissal, and when it goes.
@MainActor
@Suite struct DismissedWarnings {
    private func entry() -> Entry {
        Entry(
            recording: URL(filePath: "/nowhere/lecture.wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
            subtitles: false)
    }

    /// Records hold these names, so a new name is added and none is changed.
    @Test func theStoredNamesStayTheSame() {
        #expect(
            Entry.Warning.allCases.map(\.rawValue) == [
                "glossary", "repeats", "resumed", "gaps", "leftOut", "credits", "loops",
            ])
    }

    @Test func nothingDismissedStoresNothing() {
        var entry = entry()
        entry.setDismissed(.gaps, true)
        #expect(entry.dismissedWarnings == ["gaps"])
        entry.setDismissed(.gaps, false)
        #expect(entry.dismissedWarnings == nil)
    }

    /// New text can bring a warning of the same kind about something new.
    @Test func newTextBringsThemBack() {
        var entry = entry()
        entry.setDismissed(.resumed, true)
        entry.publish([Segment(start: 0, end: 10, text: "Bonjour à tous.")], partial: false)
        #expect(entry.dismissedWarnings == nil)
    }

    /// Putting lines back rewrites the text, and a repeat's figure with it.
    @Test func puttingLinesBackBringsThemBack() {
        var entry = entry()
        entry.publish(
            [
                Segment(start: 0, end: 10, text: "Bonjour à tous."),
                Segment(start: 10, end: 13, text: Credits.lines.sorted()[0]),
            ], partial: false)
        entry.setDismissed(.repeats, true)
        let putBack = entry.putBackCredits()
        #expect(putBack)
        #expect(entry.dismissedWarnings == nil)
    }

    @Test func aRetryStartsWithNone() {
        var entry = entry()
        entry.setDismissed(.resumed, true)
        #expect(entry.retrying().dismissedWarnings == nil)
    }

    @Test func aDismissalOutlivesTheApp() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appending(path: "History")
        let entry = entry()
        try HistoryStore.write(entry, in: history)
        let model = AppModel(history: history)

        model.setDismissed([.gaps], true, on: entry.id)
        await model.finishWrites()

        let stored = try #require(HistoryStore.all(in: history).entries.first)
        #expect(stored.isDismissed(.gaps))
        #expect(!stored.isDismissed(.resumed))
    }

    /// As the capsule's button does: the text is clear, the inspector keeps them.
    @Test func dismissingThemAllClearsTheTextOnly() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appending(path: "History")
        var written = entry()
        written.glossaryWarning = "The glossary could not be read."
        written.resumedAt = [612]
        try HistoryStore.write(written, in: history)
        let model = AppModel(history: history)
        func checks() throws -> TextChecks {
            let entry = try #require(model.entry(written.id))
            return TextChecks(
                entry: entry, findings: entry.findings, canRebuild: true, model: model,
                isRunning: false, engine: nil)
        }
        #expect(try checks().aboveText.map(\.warning) == [.glossary, .resumed])

        model.setDismissed(try checks().aboveText.map(\.warning), true, on: written.id)

        #expect(try checks().aboveText.isEmpty)
        #expect(try checks().all.map(\.warning) == [.glossary, .resumed])
    }
}
