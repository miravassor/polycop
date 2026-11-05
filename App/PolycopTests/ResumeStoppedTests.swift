// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats/clip.wav")

private let first = Segment(start: 0, end: 1, text: "Bonjour à tous.")

/// A folder with a recording and a transcript of it stopped after its first
/// segment, as the scripted engine would continue it.
@MainActor
private struct Stopped {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let id: Entry.ID
    let opener: Opener
    let model: AppModel

    init(_ engine: ScriptedEngine = ScriptedEngine()) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = folder.appending(path: "lecture.wav")
        try FileManager.default.copyItem(at: clip, to: recording)
        var entry = Entry(
            recording: recording, modelFile: ModelCatalog.recommended.id, glossary: nil,
            skipsSilence: false, subtitles: false, language: "en")
        entry.publish([first], partial: true)
        entry.state = .stopped
        let history = folder.appending(path: "History")
        try HistoryStore.write(entry, in: history)
        id = entry.id
        opener = Opener(engine)
        model = AppModel(history: history, engines: opener.engines)
    }
}

/// Polls until `condition` holds, for up to about ten seconds.
@MainActor
private func until(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

@MainActor
@Suite struct ResumingAStoppedTranscript {
    @Test func itContinuesFromWhereItStoppedInTheSameTranscript() async throws {
        let engine = ScriptedEngine()
        let job = try Stopped(engine)
        let (folder, id, model) = (job.folder, job.id, job.model)
        let opener = job.opener
        defer { try? FileManager.default.removeItem(at: folder) }

        model.resumeStopped(id)
        try await until { !model.hasWork && !model.stage.isBusy }

        let entry = try #require(model.entry(id))
        #expect(model.entries.count == 1)
        #expect(entry.state == .finished)
        #expect(!entry.isPartial)
        #expect(entry.decoded.count == 3)
        #expect(entry.decoded.first == first)
        #expect(entry.paragraphs.map(\.text).joined().contains("Voici le plan."))
        #expect(entry.resumedAt == [first.end])
        #expect(engine.starts == [first.end])
        #expect(opener.opened == 1)
        await model.shutDown()
    }

    /// The settings on the page may have changed since it ran.
    @Test func itKeepsTheSettingsItWasGiven() async throws {
        let job = try Stopped()
        let (folder, id, model) = (job.folder, job.id, job.model)
        let opener = job.opener
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = ModelCatalog.turboQuantized.id
        opener.installed.insert(other)
        model.refreshInstalled()
        model.selected = other
        model.language = "fr"

        model.resumeStopped(id)
        try await until { !model.hasWork && !model.stage.isBusy }

        #expect(model.entry(id)?.modelFile == ModelCatalog.recommended.id)
        #expect(model.entry(id)?.language == "en")
        await model.shutDown()
    }

    @Test func aStopWhileResumedKeepsWhatItHad() async throws {
        let engine = ScriptedEngine(holdsAt: 2)
        let job = try Stopped(engine)
        let (folder, id, model) = (job.folder, job.id, job.model)
        defer { try? FileManager.default.removeItem(at: folder) }

        model.resumeStopped(id)
        try await until { engine.isHolding }
        #expect(model.entry(id)?.state == .running)
        model.cancel()
        engine.release()
        try await until { !model.stage.isBusy }

        #expect(model.entry(id)?.state == .stopped)
        #expect(model.entry(id)?.decoded.count == 2)
        await model.shutDown()
    }

    @Test func aRecordingGoneLeavesItStopped() async throws {
        let job = try Stopped()
        let (folder, id, model) = (job.folder, job.id, job.model)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.removeItem(at: folder.appending(path: "lecture.wav"))

        model.resumeStopped(id)

        #expect(model.entry(id)?.state == .stopped)
        #expect(model.entry(id)?.paragraphs.map(\.text) == [first.text])
        await model.shutDown()
    }

    @Test func correctionsAreNeverWrittenOver() async throws {
        let engine = ScriptedEngine()
        let job = try Stopped(engine)
        let (folder, id, model) = (job.folder, job.id, job.model)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.edit(id, paragraphAt: 0, text: "Corrected.")
        let entry = try #require(model.entry(id))
        #expect(!model.canResume(entry))

        model.resumeStopped(id)

        #expect(model.entry(id)?.state == .stopped)
        #expect(model.entry(id)?.paragraphs.map(\.text) == ["Corrected."])
        #expect(engine.starts.isEmpty)
        await model.shutDown()
    }

    /// A course's corrections count as edits but are not the user's here: a new
    /// layout applies them again, and to the new text as well.
    @Test func aCoursesCorrectionsDoNotStopItAndReachTheNewText() async throws {
        let job = try Stopped()
        let (folder, id, model) = (job.folder, job.id, job.model)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.updateEntry(id) {
            $0.courseCorrections = [
                CourseCorrection(text: "Bonjour", replacement: "Salut"),
                CourseCorrection(text: "plan", replacement: "programme"),
            ]
            $0.publish($0.decoded, partial: true)
        }
        let entry = try #require(model.entry(id))
        #expect(entry.isEdited)
        #expect(model.canResume(entry))

        model.resumeStopped(id)
        try await until { !model.hasWork && !model.stage.isBusy }

        let text = model.entry(id)?.paragraphs.map(\.text).joined()
        #expect(text?.contains("Salut à tous.") == true)
        #expect(text?.contains("Voici le programme.") == true)
        await model.shutDown()
    }

    @Test func aModelNoLongerInstalledLeavesItStopped() async throws {
        let job = try Stopped()
        let (folder, id, model) = (job.folder, job.id, job.model)
        let opener = job.opener
        defer { try? FileManager.default.removeItem(at: folder) }
        opener.installed = []

        model.resumeStopped(id)

        #expect(model.entry(id)?.state == .stopped)
        #expect(model.scheduled.isEmpty)
        await model.shutDown()
    }

    @Test func otherWorkKeepsItStopped() async throws {
        let engine = ScriptedEngine(holdsAt: 0)
        let job = try Stopped(engine)
        let (folder, id, model) = (job.folder, job.id, job.model)
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appending(path: "other.wav")
        try FileManager.default.copyItem(at: clip, to: other)
        model.transcribe([other])
        model.start()
        try await until { engine.isHolding }
        let entry = try #require(model.entry(id))
        #expect(!model.canResume(entry))

        model.resumeStopped(id)

        #expect(model.entry(id)?.state == .stopped)
        engine.release()
        await model.shutDown()
    }

    /// A transcript that stopped before any text has nothing to continue.
    @Test func withoutTextThereIsNothingToResume() throws {
        let job = try Stopped()
        let (folder, id, model) = (job.folder, job.id, job.model)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.updateEntry(id) { $0.decoded = [] }
        #expect(try !model.canResume(#require(model.entry(id))))
    }

    @Test func aFinishedTranscriptIsNotResumed() throws {
        let job = try Stopped()
        let (folder, id, model) = (job.folder, job.id, job.model)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.updateEntry(id) { $0.state = .finished }
        #expect(try !model.canResume(#require(model.entry(id))))
    }
}
