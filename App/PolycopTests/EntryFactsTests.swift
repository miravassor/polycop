// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import Testing
import os

@testable import Polycop

/// Every field of the inspector's facts types, and that corrections typed in
/// the text or replaced across it leave them equal so the inspector skips its
/// body.
@MainActor
@Suite struct EntryFactsTests {
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

        var changed = base
        changed.id = UUID()
        #expect(changed != base)

        changed = base
        changed.canExport = false
        #expect(changed != base)
        #expect(!EntryExportSection.Facts(entry: entry, isRunning: true, lastExport: nil).canExport)

        changed = base
        changed.exportFormat = .markdown
        #expect(changed != base)

        changed = base
        changed.exportsTimes = !base.exportsTimes
        #expect(changed != base)

        changed = base
        changed.formats = [.plainText]
        #expect(changed != base)

        let german = sampleEntry(language: "de")
        let germanFacts = EntryExportSection.Facts(entry: german, isRunning: false, lastExport: nil)
        #expect(!germanFacts.coversHesitations)
        changed = base
        changed.coversHesitations = false
        #expect(changed != base)

        changed = base
        changed.removesHesitations = true
        #expect(changed != base)

        changed = base
        changed.lastExport = URL(filePath: "/nowhere/export.txt")
        #expect(changed != base)
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

        let custom = EntryDetails.Facts(sampleEntry(modelFile: "custom.bin"))
        #expect(custom.modelName == "custom.bin")

        var changed = base
        changed.added = entry.added.addingTimeInterval(60)
        #expect(changed != base)
        changed = base
        changed.importSource = "notes.srt"
        #expect(changed != base)
        changed = base
        changed.modelName = "Other"
        #expect(changed != base)
        changed = base
        changed.transcribedIn = 99
        #expect(changed != base)
        changed = base
        changed.isLanguageDetected = true
        #expect(changed != base)
        changed = base
        changed.language = "English"
        #expect(changed != base)
        changed = base
        changed.glossary = "Physique"
        #expect(changed != base)
        changed = base
        changed.skipsSilence = true
        #expect(changed != base)
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

    private func with<T>(_ value: T, _ edit: (inout T) -> Void) -> T {
        var copy = value
        edit(&copy)
        return copy
    }
}
