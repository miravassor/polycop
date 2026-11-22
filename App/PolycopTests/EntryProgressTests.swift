// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Polycop

private struct ProgressSnapshot: Equatable {
    let isIndeterminate: Bool
    let value: Double
}

/// An isolated model in temporary folders of its own, shut down and cleaned up on exit.
@MainActor
private func withIsolatedModel(
    _ body: (AppModel, URL) async throws -> Void
) async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let model = AppModel(
        history: folder.appending(path: "History"),
        glossaries: folder.appending(path: "Glossaries"),
        models: folder.appending(path: "Models"),
        playbackCopies: folder.appending(path: "Replay"),
        defaults: MemoryDefaults())
    model.keepAwake = false
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

/// Hosts `view` in a non-key transparent window so SwiftUI lays out and bridges
/// its progress indicator, then returns its measured size and indicator state.
@MainActor
private func inspectHosted(
    _ view: some View
) async -> (size: CGSize, indicators: [ProgressSnapshot]) {
    func indicators(in view: NSView) -> [NSProgressIndicator] {
        ((view as? NSProgressIndicator).map { [$0] } ?? [])
            + view.subviews.flatMap(indicators(in:))
    }

    let controller = NSHostingController(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFront(nil)
    defer { window.close() }

    window.layoutIfNeeded()
    await turns(2)

    let size = controller.sizeThatFits(in: CGSize(width: 800, height: 200))
    let snapshots = indicators(in: controller.view).map {
        ProgressSnapshot(isIndeterminate: $0.isIndeterminate, value: $0.doubleValue)
    }
    return (size, snapshots)
}

private func sampleEntry(in folder: URL, state: Entry.State, withText: Bool = true) -> Entry {
    var entry = Entry(
        recording: folder.appending(path: "lecture.wav"),
        modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
        subtitles: false)
    if withText {
        entry.publish([Segment(start: 0, end: 12, text: "Good morning everyone.")], partial: true)
    }
    entry.state = state
    return entry
}

@MainActor
@Test func transcriptionStatusShowsProgressAcrossStages() async throws {
    try await withIsolatedModel { model, _ in
        model.stage = .transcribing(0.42)
        let transcribing = await inspectHosted(TranscriptionStatus(model: model))
        #expect(transcribing.size.width > 0 && transcribing.size.height > 0)
        let transcribingBar = try #require(transcribing.indicators.first)
        #expect(transcribing.indicators.count == 1)
        #expect(!transcribingBar.isIndeterminate)
        #expect(abs(transcribingBar.value - 0.42) < 0.001)

        model.stage = .paused(0.42)
        let paused = await inspectHosted(TranscriptionStatus(model: model))
        #expect(paused.size.width > 0 && paused.size.height > 0)
        let pausedBar = try #require(paused.indicators.first)
        #expect(!pausedBar.isIndeterminate)
        #expect(abs(pausedBar.value - 0.42) < 0.001)

        model.stage = .downloading(0.65)
        let downloading = await inspectHosted(TranscriptionStatus(model: model))
        #expect(downloading.size.width > 0 && downloading.size.height > 0)
        let downloadingBar = try #require(downloading.indicators.first)
        #expect(!downloadingBar.isIndeterminate)
        #expect(abs(downloadingBar.value - 0.65) < 0.001)

        model.stage = .repairing(0.5)
        let repairing = await inspectHosted(TranscriptionStatus(model: model))
        #expect(repairing.size.width > 0 && repairing.size.height > 0)
        let repairingBar = try #require(repairing.indicators.first)
        #expect(!repairingBar.isIndeterminate)
        #expect(abs(repairingBar.value - 0.5) < 0.001)

        for stage in [AppModel.Stage.loading, .decoding, .stopping] {
            model.stage = stage
            let hosted = await inspectHosted(TranscriptionStatus(model: model))
            #expect(hosted.size.width > 0 && hosted.size.height > 0)
            #expect(try #require(hosted.indicators.first).isIndeterminate)
            if stage == .stopping {
                #expect(hosted.size.width < transcribing.size.width)
            }
        }
    }
}

@MainActor
@Test func entryProgressShowsACapsuleForActiveAndPartialEndedStates() async throws {
    try await withIsolatedModel { model, folder in
        model.stage = .transcribing(0.42)
        let running = await inspectHosted(
            EntryProgress(
                model: model, entry: sampleEntry(in: folder, state: .running, withText: false),
                isRunning: true))
        #expect(running.size.width > 0 && running.size.height > 0)
        #expect(try !#require(running.indicators.first).isIndeterminate)

        model.downloadingModel = ModelCatalog.recommended
        model.stage = .downloading(0.65)
        let downloading = await inspectHosted(
            EntryProgress(
                model: model, entry: sampleEntry(in: folder, state: .waiting, withText: false),
                isRunning: false))
        #expect(downloading.size.width > 0 && downloading.size.height > 0)
        let downloadingBar = try #require(downloading.indicators.first)
        #expect(!downloadingBar.isIndeterminate)
        #expect(abs(downloadingBar.value - 0.65) < 0.001)

        model.downloadingModel = nil
        model.stage = .waiting
        let stoppedWithDecoded = sampleEntry(in: folder, state: .stopped)
        var stoppedWithoutDecoded = stoppedWithDecoded
        stoppedWithoutDecoded.decoded = []
        let withResume = await inspectHosted(
            EntryProgress(model: model, entry: stoppedWithDecoded, isRunning: false))
        let withoutResume = await inspectHosted(
            EntryProgress(model: model, entry: stoppedWithoutDecoded, isRunning: false))
        #expect(withResume.size.width > 0 && withResume.size.height > 0)
        #expect(withoutResume.size.width > 0 && withoutResume.size.height > 0)
        #expect(withResume.size.width > withoutResume.size.width)
        #expect(withResume.indicators.isEmpty && withoutResume.indicators.isEmpty)

        let failed = await inspectHosted(
            EntryProgress(
                model: model,
                entry: sampleEntry(in: folder, state: .failed("The recording could not be read.")),
                isRunning: false))
        #expect(failed.size.width > 0 && failed.size.height > 0)
        #expect(failed.indicators.isEmpty)
    }
}

@MainActor
@Test func entryProgressHidesWhenIdleOrWithoutText() async throws {
    try await withIsolatedModel { model, folder in
        let hidden = [
            sampleEntry(in: folder, state: .finished, withText: true),
            sampleEntry(in: folder, state: .waiting, withText: false),
            sampleEntry(in: folder, state: .running, withText: true),
            sampleEntry(in: folder, state: .stopped, withText: false),
            sampleEntry(
                in: folder, state: .failed("The recording could not be read."), withText: false),
        ]
        for entry in hidden {
            let hosted = await inspectHosted(
                EntryProgress(model: model, entry: entry, isRunning: false))
            #expect(hosted.size == .zero)
            #expect(hosted.indicators.isEmpty)
        }
    }
}
