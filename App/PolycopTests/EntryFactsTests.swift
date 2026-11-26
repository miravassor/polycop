// SPDX-License-Identifier: GPL-3.0-or-later
// Every test of one subject, kept together.
// swiftlint:disable file_length

import Foundation
import Observation
import Testing
import os

@testable import Polycop

@MainActor
private func sampleEntry(
    recording: URL = URL(filePath: "/nowhere/lecture.wav"),
    modelFile: String = ModelCatalog.recommended.id,
    glossary: Glossary? = Glossary(name: "Droit", text: "Mot"),
    skipsSilence: Bool = false,
    language: String = "fr",
    added: Date = Date(timeIntervalSinceReferenceDate: 1_000)
) -> Entry {
    var entry = Entry(
        recording: recording, modelFile: modelFile, glossary: glossary,
        skipsSilence: skipsSilence, subtitles: false, language: language, added: added)
    entry.publish(
        [
            Segment(start: 0, end: 3, text: "Le concept est clair."),
            Segment(start: 5, end: 8, text: "Ce concept revient souvent."),
        ], partial: false)
    entry.state = .finished
    return entry
}

@MainActor
private func creditedEntryWithGap() -> Entry {
    var entry = Entry(
        recording: URL(filePath: "/nowhere/lecture.wav"),
        modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false, language: "fr")
    let creditText = Credits.lines.sorted()[0]
    entry.publish(
        [
            Segment(
                start: 0, end: 2, text: " \(creditText)",
                words: [.init(text: "Crédit", start: 0, end: 1, confidence: 0.9)]),
            Segment(
                start: 5, end: 8, text: " Le concept est clair.",
                words: [.init(text: "Le", start: 5, end: 5.5, confidence: 0.9)]),
        ], partial: false)
    entry.duration = 200
    entry.state = .finished
    return entry
}

@MainActor
private func withModel(_ body: (AppModel, URL) async throws -> Void) async throws {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let model = AppModel(
        history: folder.appending(path: "History"),
        glossaries: folder.appending(path: "Glossaries"),
        playbackCopies: folder.appending(path: "Copies"))
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

private func with<T>(_ value: T, _ edit: (inout T) -> Void) -> T {
    var copy = value
    edit(&copy)
    return copy
}

/// Every field of the page and inspector facts types, and that corrections
/// typed in the text or replaced across it leave them equal so the page's
/// structure and inspector skip their bodies.
@MainActor
@Suite struct EntryFactsTests {
    /// Every field of `EntryExportSection.Facts` changes equality and matches
    /// what the export section reads from a record.
    @Test func exportFactsTrackEveryShownField() {
        let entry = sampleEntry()
        let base = EntryExportSection.Facts(entry: entry, isRunning: false, lastExport: nil)
        #expect(base.id == entry.id)
        #expect(base.canExport)
        #expect(base.exportFormat == entry.exportFormat)
        #expect(base.exportsTimes == entry.exportsTimes)
        #expect(base.formats == EntryExportSection.formats(for: entry))
        #expect(base.coversHesitations)
        #expect(!base.removesHesitations)
        #expect(base.lastExport == nil)
        #expect(!EntryExportSection.Facts(entry: entry, isRunning: true, lastExport: nil).canExport)
        let germanFacts = EntryExportSection.Facts(
            entry: sampleEntry(language: "de"), isRunning: false, lastExport: nil)
        #expect(!germanFacts.coversHesitations)

        let variants: [EntryExportSection.Facts] = [
            with(base) { $0.id = UUID() },
            with(base) { $0.canExport = false },
            with(base) { $0.exportFormat = .markdown },
            with(base) { $0.exportsTimes.toggle() },
            with(base) { $0.formats = [.plainText] },
            with(base) { $0.coversHesitations = false },
            with(base) { $0.removesHesitations = true },
            with(base) { $0.lastExport = URL(filePath: "/nowhere/export.txt") },
        ]
        for variant in variants { #expect(variant != base) }
    }

    /// Every field of `EntryDetails.Facts` changes equality and matches what
    /// the details section shows.
    @Test func detailsFactsTrackEveryShownField() {
        var entry = sampleEntry()
        entry.transcribedIn = 42
        let base = EntryDetails.Facts(entry)
        #expect(base.added == entry.added)
        #expect(base.importSource == nil)
        #expect(base.modelName == ModelCatalog.recommended.name)
        #expect(base.transcribedIn == 42)
        #expect(!base.isLanguageDetected)
        #expect(base.language == DecodingSettings.name(of: "fr"))
        #expect(base.glossary == "Droit")
        #expect(!base.skipsSilence)

        let detected = EntryDetails.Facts(sampleEntry(language: DecodingSettings.automaticLanguage))
        #expect(detected.isLanguageDetected)
        #expect(detected.language == nil)
        #expect(EntryDetails.Facts(sampleEntry(modelFile: "custom.bin")).modelName == "custom.bin")

        let variants: [EntryDetails.Facts] = [
            with(base) { $0.added = entry.added.addingTimeInterval(60) },
            with(base) { $0.importSource = "notes.srt" },
            with(base) { $0.modelName = "Other" },
            with(base) { $0.transcribedIn = 99 },
            with(base) { $0.isLanguageDetected = true },
            with(base) { $0.language = "English" },
            with(base) { $0.glossary = "Physique" },
            with(base) { $0.skipsSilence = true },
        ]
        for variant in variants { #expect(variant != base) }
    }

    /// Every field of `TextChecks.Facts` changes equality, and `TextChecks`
    /// reads dismissal and busyness from facts rather than the model's stage.
    @Test func textCheckFactsTrackEveryWarningField() async throws {
        let base = TextChecks.Facts(
            id: UUID(), glossaryWarning: nil,
            findings: Entry.Findings(
                repetitionWarning: nil, repeats: [], hiddenCredits: [], shortenedLoops: []),
            resumedAt: nil, textGaps: [], leftOut: nil, duration: nil, skipsSilence: false,
            dismissedWarnings: nil, canRebuild: true, isRunning: false, isBusy: false,
            engineSkipsSilence: true)

        let variants: [TextChecks.Facts] = [
            with(base) { $0.id = UUID() },
            with(base) { $0.glossaryWarning = "Missing glossary." },
            with(base) {
                $0.findings = Entry.Findings(
                    repetitionWarning: "Repeats.", repeats: [0...1], hiddenCredits: [],
                    shortenedLoops: [])
            },
            with(base) { $0.resumedAt = [120] },
            with(base) { $0.textGaps = [10...90] },
            with(base) { $0.leftOut = 30 },
            with(base) { $0.duration = 600 },
            with(base) { $0.skipsSilence = true },
            with(base) { $0.dismissedWarnings = [Entry.Warning.gaps.rawValue] },
            with(base) { $0.canRebuild = false },
            with(base) { $0.isRunning = true },
            with(base) { $0.isBusy = true },
            with(base) { $0.engineSkipsSilence = false },
        ]
        for variant in variants {
            #expect(variant != base)
        }

        try await withModel { model, _ in
            let repeated = with(base) {
                $0.findings = Entry.Findings(
                    repetitionWarning: "Repeats.", repeats: [0...2], hiddenCredits: [],
                    shortenedLoops: [])
            }
            let idleCheck = TextChecks(facts: repeated, model: model).all.first
            #expect(idleCheck?.action?.isDisabled == false)
            let busyCheck = TextChecks(facts: with(repeated) { $0.isBusy = true }, model: model)
                .all.first
            #expect(busyCheck?.action?.isDisabled == true)
        }
    }

    /// Every field of `EntryInspector.Facts` changes equality.
    @Test func inspectorFactsTrackEverySection() async throws {
        try await withModel { model, _ in
            let entry = sampleEntry()
            let base = EntryInspector.Facts(
                entry: entry, findings: entry.findings, textGaps: entry.textGaps,
                canRebuild: true, lastExport: nil, model: model)
            #expect(base.id == entry.id)
            #expect(base.recording == entry.recording)
            #expect(base.resume == 0)

            let variants: [EntryInspector.Facts] = [
                with(base) { $0.id = UUID() },
                with(base) { $0.recording = URL(filePath: "/nowhere/other.wav") },
                with(base) { $0.resume = 15 },
                with(base) { $0.export.exportsTimes.toggle() },
                with(base) { $0.checks.canRebuild.toggle() },
                with(base) { $0.details.skipsSilence.toggle() },
            ]
            for variant in variants {
                #expect(variant != base)
            }
        }
    }

    /// After the first correction, editing a paragraph or replacing matches
    /// across the text leaves the inspector's facts equal.
    @Test func textEditsAndReplaceAllLeaveInspectorFactsEqual() async throws {
        try await withModel { model, _ in
            let entry = sampleEntry()
            model.entries = [entry]
            let id = entry.id

            // First correction flips `canRebuild` when a rebuild is offered;
            // later edits represent normal editing on the page.
            model.edit(id, paragraphAt: 0, text: "Le concept est très clair.")
            @MainActor func facts() throws -> EntryInspector.Facts {
                let current = try #require(model.entry(id))
                return EntryInspector.Facts(
                    entry: current, findings: current.findings, textGaps: current.textGaps,
                    canRebuild: model.canRebuildParagraphs(of: current),
                    lastExport: model.lastExport(of: current), model: model)
            }

            let beforeEdit = try facts()
            model.edit(id, paragraphAt: 0, text: "Le concept est vraiment clair.")
            #expect(try facts() == beforeEdit)

            let paragraphs = try #require(model.entry(id)?.paragraphs)
            let matches = TranscriptSearch.matches(in: paragraphs, query: "concept")
            try #require(!matches.isEmpty)
            model.replace(id, matches: matches, with: "notion")
            #expect(try facts() == beforeEdit)
        }
    }

    /// Progress ticks keep `isBusy` equal and tell no view observing it.
    @Test func busyTellsItsReadersOnlyWhenWorkStartsOrEnds() async throws {
        try await withModel { model, _ in
            @MainActor func tellsBusy(_ change: () -> Void) -> Bool {
                let told = OSAllocatedUnfairLock(initialState: false)
                withObservationTracking {
                    _ = model.isBusy
                } onChange: {
                    told.withLock { $0 = true }
                }
                change()
                return told.withLock { $0 }
            }

            #expect(!model.isBusy)
            #expect(tellsBusy { model.stage = .transcribing(0.1) })
            #expect(model.isBusy)
            #expect(!tellsBusy { model.stage = .transcribing(0.2) })
            #expect(!tellsBusy { model.stage = .paused(0.2) })
            #expect(tellsBusy { model.stage = .waiting })
            #expect(!model.isBusy)
        }
    }

    /// Every field of `EntryTools.Facts` changes equality and matches what the
    /// page's tools read from a record.
    @Test func toolFactsTrackEveryField() async throws {
        try await withModel { model, _ in
            let entry = sampleEntry()
            let base = EntryTools.Facts(
                entry: entry, hasRecording: true, hasTimedWords: true, hasExport: false,
                model: model)
            #expect(base.paragraphCount == 2)
            #expect(base.flagged.isEmpty)
            #expect(!base.canUndo)
            #expect(!base.isEdited)
            #expect(base.hasRecording)
            #expect(base.hasTimedWords)
            #expect(!base.hasExport)
            #expect(!base.isRunning)
            #expect(base.hasText)

            let variants: [EntryTools.Facts] = [
                with(base) { $0.paragraphCount = 0 },
                with(base) { $0.flagged = [1] },
                with(base) { $0.canUndo = true },
                with(base) { $0.isEdited = true },
                with(base) { $0.hasRecording = false },
                with(base) { $0.hasTimedWords = false },
                with(base) { $0.hasExport = true },
                with(base) { $0.isRunning = true },
            ]
            for variant in variants {
                #expect(variant != base)
            }
        }
    }

    /// Every field of `ParagraphSteps.Facts` changes equality and matches what
    /// the Playback menu reads from a record.
    @Test func paragraphStepFactsTrackEveryField() {
        let entry = sampleEntry()
        let base = ParagraphSteps.Facts(entry: entry, hasRecording: true, hasTimedWords: false)
        #expect(base.id == entry.id)
        #expect(base.hasText)
        #expect(base.hasRecording)
        #expect(!base.hasTimedWords)

        let variants: [ParagraphSteps.Facts] = [
            with(base) { $0.id = UUID() },
            with(base) { $0.hasText = false },
            with(base) { $0.hasRecording = false },
            with(base) { $0.hasTimedWords = true },
        ]
        for variant in variants {
            #expect(variant != base)
        }
    }

    /// Every field of `EntryPage.Facts` changes equality, and edits after the
    /// first correction leave the page's facts equal.
    @Test func pageFactsTrackEveryFieldAndStayEqualAcrossEdits() async throws {
        try await withModel { model, _ in
            let entry = sampleEntry()
            model.entries = [entry]
            let id = entry.id

            model.edit(id, paragraphAt: 0, text: "Le concept est très clair.")
            @MainActor func pageFacts() throws -> EntryPage.Facts {
                let current = try #require(model.entry(id))
                let segments = PageSegments()
                segments.update(for: current, model: model)
                let inspector = EntryInspector.Facts(
                    entry: current, findings: segments.findings, textGaps: segments.textGaps,
                    canRebuild: segments.canRebuild,
                    lastExport: model.lastExport(of: current), model: model)
                return EntryPage.Facts(
                    entry: current, hasRecording: current.hasRecording,
                    hasTimedWords: segments.hasTimedWords,
                    inspector: inspector, model: model)
            }

            let base = try pageFacts()
            let variants: [EntryPage.Facts] = [
                with(base) { $0.id = UUID() },
                with(base) { $0.name = "Autre.wav" },
                with(base) { $0.tools.flagged = [0] },
                with(base) { $0.inspector.resume = 12 },
                with(base) { $0.steps.hasTimedWords = true },
            ]
            for variant in variants {
                #expect(variant != base)
            }

            model.edit(id, paragraphAt: 0, text: "Le concept est vraiment clair.")
            #expect(try pageFacts() == base)

            let paragraphs = try #require(model.entry(id)?.paragraphs)
            let matches = TranscriptSearch.matches(in: paragraphs, query: "concept")
            try #require(!matches.isEmpty)
            model.replace(id, matches: matches, with: "notion")
            #expect(try pageFacts() == base)
        }
    }

    /// `ParagraphSteps` notifies commands only when replayability or follow
    /// suspension changes, not when moving the cursor between paragraphs.
    @Test func paragraphStepsObserveReplayAndFollowSuspensionOnlyWhenTheyChange() async throws {
        try await withModel { model, _ in
            let state = PageNavigationState()
            let steps = ParagraphSteps(
                model: model,
                facts: ParagraphSteps.Facts(
                    entry: sampleEntry(), hasRecording: true, hasTimedWords: false),
                state: state)

            @MainActor func tells(_ read: () -> Void, when change: () -> Void) -> Bool {
                let told = OSAllocatedUnfairLock(initialState: false)
                withObservationTracking(read) { told.withLock { $0 = true } }
                change()
                return told.withLock { $0 }
            }

            #expect(!steps.canReplay)
            #expect(tells({ _ = steps.canReplay }, when: { state.activeParagraph = 1 }))
            #expect(steps.canReplay)
            #expect(!tells({ _ = steps.canReplay }, when: { state.activeParagraph = 4 }))
            #expect(tells({ _ = steps.canReplay }, when: { state.activeParagraph = nil }))
            #expect(!steps.canReplay)

            #expect(!steps.isFollowSuspended)
            #expect(
                tells({ _ = steps.isFollowSuspended }, when: { state.isFollowSuspended = true }))
            #expect(steps.isFollowSuspended)
            #expect(
                tells({ _ = steps.isFollowSuspended }, when: { state.isFollowSuspended = false }))
            #expect(!steps.isFollowSuspended)
        }
    }
}

extension EntryFactsTests {
    /// `PageSegments` computes derived segment data on first update, updates
    /// in place when credits are put back, and leaves them alone on text edits.
    @Test func pageSegmentsUpdateSynchronouslyAndSkipPlainEdits() async throws {
        try await withModel { model, _ in
            let entry = creditedEntryWithGap()
            model.entries = [entry]
            let id = entry.id

            let segments = PageSegments()
            segments.update(for: entry, model: model)
            let initialWords = segments.words
            let initialFindings = segments.findings
            let initialGaps = segments.textGaps
            #expect(initialWords == WordLayout.grouped(entry.shown, into: entry.paragraphs))
            #expect(segments.hasTimedWords)
            #expect(initialFindings == entry.findings)
            #expect(!initialFindings.hiddenCredits.isEmpty)
            #expect(initialGaps == entry.textGaps)
            #expect(!initialGaps.isEmpty)
            #expect(segments.canRebuild)

            model.edit(id, paragraphAt: 0, text: "Le concept est très clair.")
            segments.update(for: try #require(model.entry(id)), model: model)
            #expect(segments.words == initialWords)
            #expect(segments.findings == initialFindings)
            #expect(segments.textGaps == initialGaps)
            #expect(segments.hasTimedWords)
            #expect(!segments.canRebuild)

            model.undo(id)
            segments.update(for: try #require(model.entry(id)), model: model)
            #expect(segments.canRebuild)

            model.putBackCredits(id)
            let restored = try #require(model.entry(id))
            #expect(restored.showsCredits)
            #expect(restored.paragraphs.count == entry.paragraphs.count + 1)
            segments.update(for: restored, model: model)
            #expect(segments.words == WordLayout.grouped(restored.shown, into: restored.paragraphs))
            #expect(segments.words.count == restored.paragraphs.count)
            #expect(segments.words != initialWords)
            #expect(segments.findings.hiddenCredits.isEmpty)
            #expect(!segments.canRebuild)

            // Switching to another record refreshes every derived field.
            segments.update(for: sampleEntry(), model: model)
            #expect(!segments.hasTimedWords)
            #expect(segments.textGaps.isEmpty)
        }
    }
}
