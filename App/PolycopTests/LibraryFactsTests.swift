// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import Testing
import os

@testable import Polycop

@MainActor
private func tells(_ read: () -> Void, when change: () throws -> Void) rethrows -> Bool {
    let told = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking(read) { told.withLock { $0 = true } }
    try change()
    return told.withLock { $0 }
}

@MainActor
private func withLibraryModel(
    engines: Engines? = nil, _ body: (AppModel, URL) async throws -> Void
) async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = AppModel(
        history: folder.appending(path: "History"),
        glossaries: folder.appending(path: "Glossaries"),
        playbackCopies: folder.appending(path: "Copies"),
        engines: engines, defaults: MemoryDefaults())
    do {
        try await body(model, folder)
    } catch {
        await model.shutDown()
        try? FileManager.default.removeItem(at: folder)
        throw error
    }
    await model.shutDown()
    try? FileManager.default.removeItem(at: folder)
}

@MainActor
private func assertLibraryInStep(
    _ model: AppModel, context: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    let expected = model.entries.map(LibraryItem.init)
    #expect(model.library.items == expected, "\(context)", sourceLocation: sourceLocation)
    #expect(
        model.library.hasWaiting == model.entries.contains { $0.state == .waiting },
        "\(context)", sourceLocation: sourceLocation)
    for entry in model.entries {
        #expect(
            model.libraryItem(entry.id) == LibraryItem(entry), "\(context)",
            sourceLocation: sourceLocation)
    }
}

private func with<T>(_ value: T, _ edit: (inout T) -> Void) -> T {
    var copy = value
    edit(&copy)
    return copy
}

/// Per-record library facts: every field, observation silence across text
/// edits, and the invariant against `AppModel.entries` across every writer.
@MainActor
@Suite struct LibraryFactsTests {
    /// Every field of `LibraryItem` changes equality, matches `Entry`, and
    /// keeps flairs sorted in display order.
    @Test func libraryItemTracksEveryFieldAndSortsFlairs() {
        var entry = Entry(
            recording: URL(filePath: "/nowhere/lecture.wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil,
            skipsSilence: false, subtitles: false, added: Date(timeIntervalSinceReferenceDate: 500))
        entry.title = "Cours 1"
        entry.state = .finished
        entry.folderID = UUID()
        entry.isPinned = true
        let custom = TranscriptFlair(title: "Examens", color: .purple)
        let urgent = TranscriptFlair(kind: .urgent, title: "Urgent", color: .red)
        entry.flairs = [custom, urgent]
        entry.publish([Segment(start: 0, end: 2, text: "Bonjour.")], partial: false)
        entry.edit(paragraphAt: 0, text: "Bonjour à tous.")

        let base = LibraryItem(entry)
        #expect(base.id == entry.id)
        #expect(base.name == "Cours 1")
        #expect(base.added == entry.added)
        #expect(base.state == .finished)
        #expect(base.modelFile == entry.modelFile)
        #expect(base.folderID == entry.folderID)
        #expect(base.isPinned)
        #expect(base.flairs == [urgent, custom])
        #expect(base.hasText)
        #expect(base.isEdited)

        let variants: [LibraryItem] = [
            with(base) { $0.id = UUID() },
            with(base) { $0.name = "Autre" },
            with(base) { $0.added = entry.added.addingTimeInterval(60) },
            with(base) { $0.state = .stopped },
            with(base) { $0.modelFile = "other.bin" },
            with(base) { $0.folderID = nil },
            with(base) { $0.isPinned = false },
            with(base) { $0.flairs = [urgent] },
            with(base) { $0.hasText = false },
            with(base) { $0.isEdited = false },
        ]
        for variant in variants { #expect(variant != base) }
    }

    /// Later text edits, replacements, and non-sidebar metadata leave
    /// `LibraryFacts` quiet; sidebar-visible changes notify readers.
    @Test func libraryFactsStayQuietAcrossTextEditsAndMetadataChanges() async throws {
        try await withLibraryModel { model, folder in
            let movedDir = folder.appending(path: "Moved")
            try FileManager.default.createDirectory(at: movedDir, withIntermediateDirectories: true)
            let sameNameAudio = movedDir.appending(path: HostedPage.clipFR.lastPathComponent)
            try Data("audio".utf8).write(to: sameNameAudio)
            var entry = Entry(
                recording: HostedPage.clipFR, modelFile: ModelCatalog.recommended.id,
                glossary: nil, skipsSilence: false, subtitles: false)
            entry.publish(
                [Segment(start: 0, end: 3, text: "Le concept de droit est vaste.")], partial: false)
            entry.state = .finished
            model.entries = [entry]
            let id = entry.id

            @MainActor func readAll() {
                _ = model.library.items
                _ = model.libraryItem(id)
                _ = model.customFlairs
                _ = model.folderFlairs
                _ = model.library.hasWaiting
            }

            // First edit flips `isEdited` from false to true, which notifies once.
            #expect(
                tells(readAll) { model.edit(id, paragraphAt: 0, text: "Le concept est clair.") })
            #expect(model.libraryItem(id)?.isEdited == true)

            // Later edits, Replace All, review flags, warnings, export settings,
            // reading place, and relinking do not notify library readers.
            #expect(
                !tells(readAll) { model.edit(id, paragraphAt: 0, text: "Le concept est précis.") })
            let paragraphs = try #require(model.entry(id)?.paragraphs)
            let matches = TranscriptSearch.matches(in: paragraphs, query: "concept")
            #expect(!tells(readAll) { model.replace(id, matches: matches, with: "principe") })
            #expect(!tells(readAll) { model.toggleReview(id, paragraphAt: 0) })
            #expect(!tells(readAll) { model.setDismissed([.gaps], true, on: id) })
            #expect(!tells(readAll) { model.setExport(.markdown, times: false, for: id) })
            #expect(!tells(readAll) { model.setRemovesHesitations(true, for: id) })
            model.readingParagraph = 0
            #expect(!tells(readAll) { model.rememberPlace(in: .entry(id)) })
            #expect(!tells(readAll) { model.locateRecording(id, at: sameNameAudio) })

            // Sidebar-visible changes notify readers.
            #expect(tells(readAll) { model.rename(id, to: "Cours de droit") })
            #expect(tells(readAll) { model.setPinned([id], to: true) })
            let todo = TranscriptFlair(kind: .todo, title: "To Do", color: .orange)
            #expect(tells(readAll) { model.toggleFlair(todo, on: [id]) })
            #expect(tells(readAll) { model.revert(id) })
            #expect(model.libraryItem(id)?.isEdited == false)
        }
    }

    /// `hasWaiting` notifies only when the queue goes empty or non-empty.
    @Test func hasWaitingNotifiesOnlyWhenWaitingStatusFlips() async throws {
        try await withLibraryModel { model, folder in
            let first = folder.appending(path: "a.wav")
            let second = folder.appending(path: "b.wav")
            try Data("a".utf8).write(to: first)
            try Data("b".utf8).write(to: second)

            @MainActor func readWaiting() { _ = model.library.hasWaiting }
            #expect(!model.library.hasWaiting)
            #expect(tells(readWaiting) { model.transcribe([first]) })
            #expect(model.library.hasWaiting)
            #expect(!tells(readWaiting) { model.transcribe([second]) })
            #expect(tells(readWaiting) { model.clearQueue() })
            #expect(!model.library.hasWaiting)
        }
    }

    /// Every writer that mutates `entries` or `folders` keeps `LibraryFacts`
    /// exact against `model.entries` and `model.libraryItem(_:)`.
    @Test func everyWriterKeepsLibraryFactsInStep() async throws {
        try await withLibraryModel(engines: Opener(ScriptedEngine()).engines) { model, _ in
            try await exerciseTranscriptionAndEditingWriters(on: model)
            try await exerciseOrganizationAndRemovalWriters(on: model)
        }
    }

    private func exerciseTranscriptionAndEditingWriters(on model: AppModel) async throws {
        model.transcribe([HostedPage.clipFR])
        let firstID = try #require(model.entries.first?.id)
        assertLibraryInStep(model, context: "transcribe")

        model.start()
        for _ in 0..<200 where model.hasWork || model.stage.isBusy {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.entry(firstID)?.state == .finished)
        assertLibraryInStep(model, context: "start and finish")

        model.edit(firstID, paragraphAt: 0, text: "Texte corrigé concept.")
        assertLibraryInStep(model, context: "edit")

        let paragraphs = try #require(model.entry(firstID)?.paragraphs)
        let matches = TranscriptSearch.matches(in: paragraphs, query: "concept")
        model.replace(firstID, matches: matches, with: "notion")
        assertLibraryInStep(model, context: "replace")

        model.undo(firstID)
        assertLibraryInStep(model, context: "undo")

        model.revert(firstID)
        assertLibraryInStep(model, context: "revert")

        model.rename(firstID, to: "Cours 1")
        assertLibraryInStep(model, context: "rename")

        let duplicateID = try #require(model.duplicate(firstID))
        assertLibraryInStep(model, context: "duplicate")

        model.retry(duplicateID)
        for _ in 0..<200 where model.hasWork || model.stage.isBusy {
            try await Task.sleep(for: .milliseconds(25))
        }
        assertLibraryInStep(model, context: "retry")

        var withCredits = Entry(
            recording: HostedPage.clipFR, modelFile: ModelCatalog.recommended.id,
            glossary: nil, skipsSilence: false, subtitles: false)
        withCredits.publish(
            [
                Segment(start: 0, end: 2, text: "Bonjour."),
                Segment(start: 2, end: 4, text: Credits.lines.sorted()[0]),
            ], partial: false)
        withCredits.state = .finished
        model.entries.insert(withCredits, at: 0)
        assertLibraryInStep(model, context: "insert credits entry")
        model.putBackCredits(withCredits.id)
        assertLibraryInStep(model, context: "putBackCredits")
    }

    private func exerciseOrganizationAndRemovalWriters(on model: AppModel) async throws {
        let ids = model.entries.map(\.id)
        let primaryID = try #require(ids.first)
        let secondaryID = try #require(ids.dropFirst().first)

        let folderA = try model.createFolder(named: "Droit")
        let folderB = try model.createFolder(named: "Histoire")
        assertLibraryInStep(model, context: "createFolder")

        try model.renameFolder(folderA, to: "Droit civil")
        try model.setFolderColor(folderA, to: .blue)
        assertLibraryInStep(model, context: "renameFolder and setFolderColor")

        model.setPinned([primaryID], to: true)
        assertLibraryInStep(model, context: "setPinned")

        let done = TranscriptFlair(kind: .done, title: "Done", color: .green)
        model.toggleFlair(done, on: [primaryID, secondaryID])
        assertLibraryInStep(model, context: "toggleFlair")

        model.addCustomTag(named: "Partiel", color: .orange, to: [primaryID])
        assertLibraryInStep(model, context: "addCustomTag")
        #expect(model.customFlairs.map(\.title) == ["Partiel"])

        model.moveEntry(primaryID, to: folderA)
        assertLibraryInStep(model, context: "moveEntry")
        #expect(model.folderFlairs[folderA]?.isEmpty == false)

        model.moveEntries([primaryID, secondaryID], to: folderB)
        assertLibraryInStep(model, context: "moveEntries")
        #expect(model.folderFlairs[folderA] == nil)
        #expect(model.folderFlairs[folderB]?.isEmpty == false)

        model.clearFlairs(on: [primaryID, secondaryID])
        assertLibraryInStep(model, context: "clearFlairs")
        #expect(model.customFlairs.isEmpty)

        try model.removeFolder(folderA)
        assertLibraryInStep(model, context: "removeFolder")

        model.removeEntry(primaryID)
        assertLibraryInStep(model, context: "removeEntry")
        #expect(model.libraryItem(primaryID) == nil)

        model.recoverEntry(primaryID)
        assertLibraryInStep(model, context: "recoverEntry")
        #expect(model.libraryItem(primaryID) != nil)

        model.removeEntries([primaryID, secondaryID])
        assertLibraryInStep(model, context: "removeEntries")
        #expect(model.libraryItem(primaryID) == nil)
        #expect(model.libraryItem(secondaryID) == nil)
        await model.finishWrites()
    }
}
