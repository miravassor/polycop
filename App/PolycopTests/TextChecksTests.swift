// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
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

@MainActor
@Suite struct TimesOfACheck {
    private func check(times count: Int) -> TextCheck {
        TextCheck(
            warning: .resumed, symbol: "arrow.clockwise", text: "Resumed part way.",
            times: (0..<count).map {
                TextCheck.Time(title: "time \($0)", help: "Listen", listen: {})
            },
            isDismissed: false, canChangeDismissal: true, setDismissed: { _ in })
    }

    @Test func aShortListStaysWhole() {
        #expect(check(times: 4).shortenedTimes.count == 4)
    }

    /// "and 1 more" would take as much room as the time it hides.
    @Test func oneOverTheLimitStillShows() {
        #expect(check(times: 5).shortenedTimes.count == 5)
    }

    @Test func aLongListStopsAtItsFirstTimes() {
        let shortened = check(times: 12).shortenedTimes
        #expect(shortened.map(\.title) == ["time 0", "time 1", "time 2", "time 3"])
    }
}

/// Measured as a window would: the height at a given width.
@MainActor
@Suite struct WrappingRows {
    private func size(_ count: Int, within width: CGFloat?) -> CGSize {
        let layout = WrappingLayout {
            ForEach(0..<count, id: \.self) { _ in
                Color.clear.frame(width: 40, height: 10)
            }
        }
        return NSHostingController(rootView: layout)
            .sizeThatFits(in: CGSize(width: width ?? .infinity, height: .infinity))
    }

    @Test func staysOnOneRowWithTheRoom() {
        #expect(size(3, within: nil) == CGSize(width: 136, height: 10))
        #expect(size(3, within: 136) == CGSize(width: 136, height: 10))
    }

    @Test func startsANewRowWhereTheNextDoesNotFit() {
        #expect(size(3, within: 135) == CGSize(width: 88, height: 24))
        #expect(size(5, within: 100) == CGSize(width: 88, height: 38))
    }

    @Test func oneTooWideKeepsItsOwnRow() {
        #expect(size(2, within: 30) == CGSize(width: 40, height: 24))
    }
}

/// Default folder and importer outcomes when a transcript's recording is missing.
@MainActor
@Suite struct LocatingAMissingRecording {
    private struct PanelFailure: LocalizedError {
        var errorDescription: String? { "The file panel could not open." }
    }

    @Test func existingParentFolderIsOffered() throws {
        let folder = URL.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = folder.appending(path: "lecture.wav")
        #expect(EntryNotices.locateDirectory(for: recording) == folder)
    }

    @Test func missingParentFolderFallsBackToNil() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let missing = folder.appending(path: "Moved/lecture.wav")
        #expect(EntryNotices.locateDirectory(for: missing) == nil)
        let remote = try #require(URL(string: "https://example.com/lecture.wav"))
        #expect(EntryNotices.locateDirectory(for: remote) == nil)
    }

    @Test func nonDirectoryParentFallsBackToNil() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let regularFile = folder.appending(path: "not-a-folder")
        try Data("x".utf8).write(to: regularFile)
        let underFile = regularFile.appending(path: "lecture.wav")
        #expect(EntryNotices.locateDirectory(for: underFile) == nil)
    }

    /// Clean transcripts emit no notice view and add no stack gap; a missing
    /// recording renders its notice above the text.
    @Test func cleanNoticesAddNoSpaceAndMissingRecordingRenders() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = folder.appending(path: "lecture.wav")
        try Data("audio".utf8).write(to: recording)
        var entry = Entry(
            recording: recording, modelFile: ModelCatalog.recommended.id, glossary: nil,
            skipsSilence: false, subtitles: false)
        entry.state = .finished
        let model = AppModel(
            history: folder.appending(path: "History"), defaults: MemoryDefaults())

        func height(for entry: Entry) -> CGFloat {
            let stack = VStack(alignment: .leading, spacing: Spacing.block) {
                Group {
                    EntryNotices(
                        entry: entry, findings: entry.findings, canRebuild: false, model: model,
                        isRunning: false, engine: nil)
                }
                .frame(maxWidth: .infinity)
                Color.clear.frame(width: 100, height: 20)
            }
            return NSHostingController(rootView: stack)
                .sizeThatFits(in: CGSize(width: CGFloat(600), height: .infinity))
                .height
        }

        #expect(height(for: entry) == 20)

        try FileManager.default.removeItem(at: recording)

        #expect(height(for: entry) > 20 + Spacing.block)
    }

    /// An importer error stays on this transcript and clears once the recording
    /// is located.
    @Test func importerFailureShowsOnThisTranscriptAndClearsOnRelink() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appending(path: "History")
        var entry = Entry(
            recording: folder.appending(path: "missing.wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        entry.state = .finished
        let other = Entry(
            recording: folder.appending(path: "other.wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        try HistoryStore.write(entry, in: history)
        try HistoryStore.write(other, in: history)
        let model = AppModel(history: history, defaults: MemoryDefaults())
        let stored = try #require(model.entry(entry.id))
        let notices = EntryNotices(
            entry: stored, findings: stored.findings, canRebuild: false, model: model,
            isRunning: false, engine: nil)

        notices.applyLocatedRecording(.failure(PanelFailure()))

        #expect(model.failure(for: entry.id) == "The file panel could not open.")
        #expect(model.failure(for: other.id) == nil)
        #expect(model.failure == nil)

        // An error for an entry no longer in the library is ignored.
        let unknown = UUID()
        model.report(PanelFailure(), for: unknown)
        #expect(model.failure(for: unknown) == nil)
        #expect(model.failure(for: entry.id) == "The file panel could not open.")

        let relocated = folder.appending(path: "relocated.wav")
        try Data("audio".utf8).write(to: relocated)
        notices.applyLocatedRecording(.success(relocated))
        await model.finishWrites()

        #expect(model.failure(for: entry.id) == nil)
        #expect(model.entry(entry.id)?.hasRecording == true)
        #expect(
            model.entry(entry.id)?.location.resolvingSymlinksInPath()
                == relocated.resolvingSymlinksInPath())
    }
}
