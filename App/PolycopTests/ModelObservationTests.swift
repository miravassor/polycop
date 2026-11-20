// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import Testing
import os

@testable import Polycop

// What the model tells the views that read it. A view told runs its body
// again, with everything it declares: each change of what it reads must tell
// it, and nothing else should. Where a write that changes nothing still tells,
// a known issue says so, until such writes tell no view.

/// Whether `change` tells the readers of what `read` reads.
@MainActor
private func tells(_ read: () -> Void, when change: () async -> Void) async -> Bool {
    let told = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking(read) { told.withLock { $0 = true } }
    await change()
    return told.withLock { $0 }
}

/// Runs `body` on a model of a library of one finished transcript, in a folder
/// of its own, given the transcript's id and the library's history folder.
@MainActor
private func withLibrary(_ body: (AppModel, Entry.ID, URL) async throws -> Void) async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    var entry = Entry(
        recording: HostedPage.clipFR, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 3, text: "Original.")], partial: false)
    entry.state = .finished
    let history = folder.appending(path: "History")
    try HistoryStore.write(entry, in: history)
    let model = AppModel(
        history: history, glossaries: folder.appending(path: "Glossaries"),
        playbackCopies: folder.appending(path: "Copies"))
    do {
        try await body(model, entry.id, history)
    } catch {
        await model.shutDown()
        try? FileManager.default.removeItem(at: folder)
        throw error
    }
    // Writes asked meanwhile end first, or one would make the folder again.
    await model.shutDown()
    try? FileManager.default.removeItem(at: folder)
}

/// Unsaved changes are shown on the page: a write that fails tells it, and so
/// does the one that saves them at last; one that succeeds with nothing
/// unsaved should not.
@MainActor
@Test func unsavedChangesTellTheirReadersOnlyWhenTheyComeOrGo() async throws {
    try await withLibrary { model, id, history in
        let entry = try #require(model.entry(id))
        @MainActor func read() { _ = model.hasUnsavedHistory }
        @MainActor func write() async {
            model.store(entry)
            await model.finishWrites()
        }

        let saved = await tells(read, when: write)
        withKnownIssue("A write that succeeds removes an id the unsaved ones lack, and tells") {
            #expect(!saved)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: history.path)
        let failed = await tells(read, when: write)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: history.path)
        #expect(failed)
        #expect(model.hasUnsavedHistory)

        let recovered = await tells(read, when: write)
        #expect(recovered)
        #expect(!model.hasUnsavedHistory)
    }
}

/// Undo Last Correction is offered once a correction can be stepped back: the
/// first correction and the undo of the last tell its readers, a second
/// correction should not.
@MainActor
@Test func undoTellsItsReadersWhenItBecomesPossibleOrNot() async throws {
    try await withLibrary { model, id, _ in
        @MainActor func read() { _ = model.canUndo(id) }

        let first = await tells(read) { model.edit(id, paragraphAt: 0, text: "Premier.") }
        #expect(first)
        let second = await tells(read) { model.edit(id, paragraphAt: 0, text: "Deuxième.") }
        withKnownIssue("Each correction adds a step to the undo steps every reader reads") {
            #expect(!second)
        }
        model.undo(id)
        let last = await tells(read) { model.undo(id) }
        #expect(last)
        #expect(!model.canUndo(id))
    }
}

/// The library's list reads every record: a change of one tells it, an update
/// that changes nothing, such as leaving a transcript with no place to keep,
/// should not.
@MainActor
@Test func theLibraryTellsItsReadersOnlyOfARecordThatChanged() async throws {
    try await withLibrary { model, id, _ in
        @MainActor func read() { _ = model.entries }

        let unchanged = await tells(read) { model.rememberPlace(in: .entry(id)) }
        withKnownIssue("An update changes the record in place before comparing it, and tells") {
            #expect(!unchanged)
        }
        let corrected = await tells(read) { model.edit(id, paragraphAt: 0, text: "Corrigé.") }
        #expect(corrected)
    }
}
