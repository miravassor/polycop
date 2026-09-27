// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Testing

@testable import Polycop

// Exercises the real engine and the model the app downloads, so the tests
// that transcribe run only where that model is installed. Each test keeps its
// history in a folder of its own.

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats/clip.wav")
private let modelInstalled = ModelStore.isInstalled(ModelCatalog.recommended)
/// Qwen cuts the recording into windows and times sentences with its aligner.
private let qwenInstalled = ModelStore.isInstalled(ModelCatalog.qwen)
/// Silence removal and the repair of repeats are whisper.cpp features.
private let whisperInstalled = ModelStore.isInstalled(ModelCatalog.turbo)

/// A folder holding copies of the clip under the given names.
private func recordings(_ names: String...) throws -> URL {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in names {
        try FileManager.default.copyItem(at: clip, to: folder.appending(path: name))
    }
    return folder
}

/// The number of samples the app decodes from a recording.
private func samples(ofClip recording: URL) async throws -> Int {
    try await AudioDecoder.samples(of: recording).count
}

@MainActor
private func settle(_ model: AppModel) async throws {
    for _ in 0..<1200 where model.hasWork || model.stage.isBusy {
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!model.hasWork)
}

/// A model for `body`, whose engine is let go of whatever happens inside: a test
/// ending with the engine alive aborts the process in Metal's teardown.
@MainActor
private func withModel(history: URL, _ body: (AppModel) async throws -> Void) async throws {
    let model = AppModel(history: history)
    do {
        try await body(model)
    } catch {
        await model.shutDown()
        throw error
    }
    await model.shutDown()
}

/// Three minutes of the clip with half a second between repeats, long enough to
/// pause between two windows of the engine.
private func longRecording(in folder: URL) async throws -> URL {
    let clipSamples = try await AudioDecoder.samples(of: clip)
    let gap = [Float](repeating: 0, count: AudioDecoder.sampleRate / 2)
    var samples: [Float] = []
    while samples.count < AudioDecoder.sampleRate * 180 {
        samples += clipSamples + gap
    }
    let url = folder.appending(path: "long.wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(AudioDecoder.sampleRate),
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ]
    let file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(
        AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
    let channel = try #require(buffer.floatChannelData?[0])
    try samples.withUnsafeBufferPointer { pointer in
        channel.update(from: try #require(pointer.baseAddress), count: samples.count)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
    return url
}

extension LoadingAModel {
    @MainActor
    @Test(.enabled(if: modelInstalled))
    func recordingsRunInTurnAndStayInTheList() async throws {
        let folder = try recordings("lundi.wav", "mardi.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appending(path: "History")
        var entries: [Entry] = []

        try await withModel(history: history) { model in
            model.transcribe([
                folder.appending(path: "lundi.wav"), folder.appending(path: "mardi.wav"),
            ])
            model.start()
            #expect(model.entries.map(\.name) == ["mardi.wav", "lundi.wav"])
            #expect(model.running == model.entries[1].id)
            try await settle(model)

            #expect(model.entries.map(\.state) == [.finished, .finished])
            #expect(model.entries.allSatisfy { !$0.paragraphs.isEmpty })
            entries = model.entries
        }

        #expect(AppModel(history: history).entries == entries)
    }

    /// Corrections reach the disk as they are typed, a second save updates the
    /// same file, and a file changed by hand meanwhile is left alone for a new one.
    @MainActor
    @Test(.enabled(if: modelInstalled))
    func correctionsAreKeptAndSavedToTheSameFile() async throws {
        let folder = try recordings("cours.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appending(path: "History")
        let text = folder.appending(path: "cours.txt")
        let second = folder.appending(path: "cours 2.txt")

        try await withModel(history: history) { model in
            model.transcribe([folder.appending(path: "cours.wav")])
            model.start()
            try await settle(model)
            let id = try #require(model.entries.first?.id)

            model.edit(id, paragraphAt: 0, text: "Premier essai.")
            model.savePending()
            #expect(
                HistoryStore.all(in: history).entries.first?.paragraphs.first?.text
                    == "Premier essai.")
            model.export(id, to: text)
            #expect(try String(contentsOf: text, encoding: .utf8).contains("Premier essai."))

            model.edit(id, paragraphAt: 0, text: "Second essai.")
            #expect(model.exportState(of: try #require(model.entry(id))) == .outOfDate)
            model.updateExport(id)
            #expect(try String(contentsOf: text, encoding: .utf8).contains("Second essai."))
            #expect(!FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
            #expect(model.exportState(of: try #require(model.entry(id))) == .current)

            // Annotated outside the app: the update refuses and says so rather
            // than replacing work the user did elsewhere.
            try "annoté à la main".write(to: text, atomically: true, encoding: .utf8)
            model.edit(id, paragraphAt: 0, text: "Troisième essai.")
            model.updateExport(id)
            #expect(try String(contentsOf: text, encoding: .utf8) == "annoté à la main")
            #expect(model.failure(for: id) != nil)
            #expect(!FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
        }
    }

    /// A recording whose own folder cannot be written still gets its files.
    @MainActor
    @Test(.enabled(if: modelInstalled))
    func aTranscriptCanBeSavedIntoAnotherFolder() async throws {
        let folder = try recordings("cours.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        let elsewhere = folder.appending(path: "Ailleurs")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        try await withModel(history: folder.appending(path: "History")) { model in
            model.transcribe([folder.appending(path: "cours.wav")])
            model.start()
            try await settle(model)
            let id = try #require(model.entries.first?.id)

            model.export(id, to: elsewhere.appending(path: "cours.txt"))

            #expect(model.entry(id)?.saved.map(\.lastPathComponent) == ["cours.txt"])
            #expect(
                FileManager.default.fileExists(
                    atPath: elsewhere.appending(path: "cours.txt").path(percentEncoded: false)))
        }
    }

    /// Cancel stops the recording under way; the next one still runs.
    @MainActor
    @Test(.enabled(if: modelInstalled))
    func cancellingStopsOnlyTheRecordingUnderWay() async throws {
        let folder = try recordings("lundi.wav", "mardi.wav")
        defer { try? FileManager.default.removeItem(at: folder) }

        try await withModel(history: folder.appending(path: "History")) { model in
            model.transcribe([
                folder.appending(path: "lundi.wav"), folder.appending(path: "mardi.wav"),
            ])
            model.start()
            model.cancel()
            try await settle(model)

            #expect(model.entries.map(\.name) == ["mardi.wav", "lundi.wav"])
            #expect(model.entries.map(\.state) == [.finished, .stopped])
        }
    }

    /// A transcription that skips silences says what it left out.
    @MainActor
    @Test(.enabled(if: whisperInstalled))
    func skippingSilencesReportsWhatWasLeftOut() async throws {
        let folder = try recordings("cours.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        let decoded = Double(try await samples(ofClip: clip)) / Double(AudioDecoder.sampleRate)

        try await withModel(history: folder.appending(path: "History")) { model in
            model.selected = ModelCatalog.turbo.id
            model.skipsSilence = true
            model.transcribe([folder.appending(path: "cours.wav")])
            model.start()
            try await settle(model)

            let entry = try #require(model.entries.first)
            let duration = try #require(entry.duration)
            let leftOut = try #require(entry.leftOut)
            #expect(entry.speech?.isEmpty == false)
            #expect(abs(duration - decoded) < 0.01)
            #expect(leftOut >= 0 && leftOut < duration)
        }
    }

    /// A pause then a resume leaves a mark where transcription started again.
    @MainActor
    @Test(.enabled(if: modelInstalled))
    func aResumeIsMarkedWhereItHappened() async throws {
        let folder = try recordings()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = try await longRecording(in: folder)

        try await withModel(history: folder.appending(path: "History")) { model in
            model.transcribe([recording])
            model.start()
            for _ in 0..<3000 {
                if case .transcribing(let progress) = model.stage, progress > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            model.pause()
            for _ in 0..<3000 {
                if case .paused = model.stage { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard case .paused = model.stage else {
                Issue.record("the transcription never paused")
                return
            }
            model.resume()
            try await settle(model)

            let entry = try #require(model.entries.first)
            #expect(entry.state == .finished)
            #expect(entry.resumedAt?.count == 1)
            #expect((entry.resumedAt?.first ?? 0) > 0)
        }
    }
}

/// What an engine cannot do is neither recorded nor offered: Qwen skips no
/// silence, whatever the page held, and its repeats cannot be repaired.
@MainActor
@Test func aModelIsOnlyGivenWhatItsEngineDoes() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    let model = AppModel(history: history)
    model.selected = ModelCatalog.qwen.id
    model.skipsSilence = true
    model.glossaryName = "Absent"

    model.transcribe([clip])

    let entry = try #require(model.entries.first)
    #expect(!model.silenceApplies && !model.glossaryApplies)
    #expect(!entry.skipsSilence)
    #expect(entry.glossary == nil && entry.prompt == nil)
    var looped = entry
    looped.publish(
        (0..<12).map { Segment(start: Double($0) * 30, end: Double($0 + 1) * 30, text: "Merci.") },
        partial: false)
    #expect(!looped.repeats.isEmpty)
    #expect(!model.canRepairRepeats(of: looped))
}

/// A job cut short by quitting cannot resume, so it comes back stopped.
@MainActor
@Test func workCutShortByQuittingComesBackStopped() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var interrupted = Entry(
        recording: clip, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    interrupted.state = .running
    try HistoryStore.write(interrupted, in: history)

    let model = AppModel(history: history)

    #expect(model.entries.map(\.state) == [.stopped])
    #expect(HistoryStore.all(in: history).entries.map(\.state) == [.stopped])
}

@MainActor
@Test func failedHistoryWritesSurviveNavigationAndCanBeRetried() async throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: history.path)
        try? FileManager.default.removeItem(at: history)
    }
    var entry = Entry(
        recording: clip, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 3, text: "Original.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    model.pane = .entry(entry.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: history.path)
    model.edit(entry.id, paragraphAt: 0, text: "Correction.")
    model.pane = .new
    #expect(model.hasUnsavedHistory)
    #expect(model.storageFailure != nil)
    await model.shutDown()
    #expect(!model.retrySavingHistory())
    #expect(
        HistoryStore.all(in: history).entries.first?.paragraphs.first?.text == "Original.")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: history.path)
    #expect(model.retrySavingHistory())
    #expect(model.storageFailure == nil)
    #expect(
        HistoryStore.all(in: history).entries.first?.paragraphs.first?.text == "Correction.")
    model.cancelTermination()
    #expect(!model.isShuttingDown)
}

@MainActor
@Test func failedRemovalKeepsTheEntryVisible() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: history.path)
        try? FileManager.default.removeItem(at: history)
    }
    var entry = Entry(
        recording: clip, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    model.pane = .entry(entry.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: history.path)
    model.removeEntry(entry.id)
    #expect(model.entry(entry.id) != nil)
    #expect(model.pane == .entry(entry.id))
    #expect(model.failure != nil)
}

@MainActor
@Test func removingAnEntryForgetsItsPendingSave() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: history) }
    var entry = Entry(
        recording: clip, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 3, text: "Original.")], partial: false)
    entry.state = .finished
    try HistoryStore.write(entry, in: history)
    let model = AppModel(history: history)
    model.edit(entry.id, paragraphAt: 0, text: "Correction.")
    #expect(model.pendingSaves.contains(entry.id))
    model.removeEntry(entry.id)
    #expect(model.pendingSaves.isEmpty)
    #expect(HistoryStore.all(in: history).entries.isEmpty)
}

extension LoadingAModel {
    @MainActor
    @Test(.enabled(if: modelInstalled))
    func quittingWhileCancellationFinishesDoesNotRestartTheQueue() async throws {
        let folder = try recordings("one.wav", "two.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(history: folder.appending(path: "History"))
        model.transcribe([folder.appending(path: "one.wav"), folder.appending(path: "two.wav")])
        model.start()
        model.cancel()
        await model.shutDown()
        await Task.yield()
        #expect(model.running == nil)
        #expect(!model.hasWork)
        #expect(model.stage == .waiting)
        #expect(model.entries.allSatisfy { $0.state == .stopped })
        model.transcribe([clip])
        model.start()
        #expect(model.entries.count == 2)
    }
}

extension LoadingAModel {
    @MainActor
    @Test(.enabled(if: modelInstalled))
    func recoveringStorageByMovingAnEntryRestartsTheQueue() async throws {
        let folder = try recordings("one.wav")
        let history = folder.appending(path: "History")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: history.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let model = AppModel(history: history)
        let destination = try model.createFolder(named: "Course")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: history.path)
        model.transcribe([folder.appending(path: "one.wav")])
        model.start()
        let id = try #require(model.entries.first?.id)
        #expect(model.running == nil)
        #expect(model.hasUnsavedHistory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: history.path)
        model.moveEntry(id, to: destination)
        #expect(!model.hasUnsavedHistory)
        #expect(model.running == id)
        await model.shutDown()
    }

    @MainActor
    @Test(.enabled(if: modelInstalled))
    func anEntryWhoseFirstWriteFailedCanBeRemoved() async throws {
        let folder = try recordings("one.wav")
        let history = folder.appending(path: "History")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: history.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let model = AppModel(history: history)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: history.path)
        model.transcribe([folder.appending(path: "one.wav")])
        model.start()
        let id = try #require(model.entries.first?.id)
        #expect(model.hasUnsavedHistory)
        model.removeEntry(id)
        #expect(model.entries.isEmpty)
        #expect(!model.hasUnsavedHistory)
        await model.shutDown()
    }
}

extension LoadingAModel {
    /// A loop is transcribed again over its own stretch of audio, with silence
    /// removal, and nothing else in the transcript moves.
    @MainActor
    @Test(.enabled(if: whisperInstalled))
    func transcribesTheRepeatsAgainAndLeavesTheRestAlone() async throws {
        let folder = try recordings("cours.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appending(path: "History")
        var entry = Entry(
            recording: folder.appending(path: "cours.wav"),
            modelFile: ModelCatalog.turbo.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        let repeated = (0..<12).map {
            Segment(start: Double($0) * 0.25, end: Double($0) * 0.25 + 0.25, text: " Merci.")
        }
        let tail = Segment(start: 3.0, end: 3.5, text: " La fin du cours.")
        entry.publish(repeated + [tail], partial: false)
        entry.state = .finished
        try HistoryStore.write(entry, in: history)

        try await withModel(history: history) { model in
            #expect(model.entry(entry.id)?.repeats == [0...11])
            #expect(model.entry(entry.id)?.repetitionWarning != nil)
            model.repairRepeats(entry.id)
            try await settle(model)

            let repaired = try #require(model.entry(entry.id))
            #expect(repaired.state == .finished)
            #expect(repaired.repeats.isEmpty)
            #expect(repaired.decoded.last == tail)
            #expect(!repaired.isSaved)
        }
    }

    /// Corrections are made on the text, and a repair rebuilds it.
    @MainActor
    @Test(.enabled(if: whisperInstalled))
    func refusesToTranscribeTheRepeatsAgainOnceTheTextIsCorrected() async throws {
        let folder = try recordings("cours.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appending(path: "History")
        var entry = Entry(
            recording: folder.appending(path: "cours.wav"),
            modelFile: ModelCatalog.turbo.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        entry.publish(
            (0..<12).map {
                Segment(start: Double($0) * 0.25, end: Double($0) * 0.25 + 0.25, text: " Merci.")
            }, partial: false)
        entry.state = .finished
        try HistoryStore.write(entry, in: history)

        try await withModel(history: history) { model in
            model.edit(entry.id, paragraphAt: 0, text: "Corrigé.")
            model.repairRepeats(entry.id)

            #expect(model.running == nil)
            #expect(model.entry(entry.id)?.paragraphs.first?.text == "Corrigé.")
        }
    }
}

extension LoadingAModel {
    @MainActor
    @Test(.enabled(if: modelInstalled)) func runningTranscriptCannotBeDuplicated() async throws {
        let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: history) }
        let model = AppModel(history: history)
        model.transcribe([clip])
        model.start()
        let id = try #require(model.entries.first?.id)
        #expect(model.duplicate(id) == nil)
        await model.shutDown()
    }

}

extension LoadingAModel {
    @MainActor
    @Test(.enabled(if: modelInstalled))
    func recordingsAddedDuringABatchWaitForAnotherStart() async throws {
        let folder = try recordings("first.wav", "later.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await withModel(history: folder.appending(path: "History")) { model in
            model.transcribe([folder.appending(path: "first.wav")])
            model.start()
            model.transcribe([folder.appending(path: "later.wav")])
            for _ in 0..<1200 where model.stage.isBusy {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(model.stage == .waiting)
            #expect(model.running == nil)
            #expect(model.entries.first?.state == .waiting)
            #expect(model.entries.last?.state == .finished)
            #expect(model.canStart)
        }
    }
}

extension LoadingAModel {
    @MainActor
    @Test(.enabled(if: qwenInstalled), arguments: [false, true])
    func stoppingKeepsCompletedWindows(quitting: Bool) async throws {
        let folder = try recordings("short.wav")
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try await longRecording(in: folder)
        let history = folder.appending(path: "History")
        try await withModel(history: history) { model in
            model.selected = ModelCatalog.qwen.id
            model.transcribe([audio])
            model.start()
            let id = try #require(model.entries.first?.id)
            var progressed = false
            for _ in 0..<1200 {
                if case .transcribing(let fraction) = model.stage, fraction > 0 {
                    progressed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(progressed)
            if quitting {
                await model.shutDown()
            } else {
                model.cancel()
                try await settle(model)
            }
            let entry = try #require(model.entry(id))
            #expect(entry.state == .stopped)
            #expect(!entry.decoded.isEmpty)
            #expect(entry.isPartial)
            #expect(entry.sentenceTimes == true || !model.alignerInstalled)
            #expect(HistoryStore.all(in: history).entries.first == entry)
        }
    }
}

/// The queue waits for a failed history write, so starting is not offered
/// until the write succeeds.
@MainActor
@Test func startingWaitsForAFailedHistoryWrite() throws {
    let history = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: history.path)
        try? FileManager.default.removeItem(at: history)
    }
    let model = AppModel(history: history)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: history.path)
    model.transcribe([clip])
    #expect(!model.waiting.isEmpty)
    #expect(model.hasUnsavedHistory)
    #expect(!model.canStart)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: history.path)
    model.clearQueue()
}
