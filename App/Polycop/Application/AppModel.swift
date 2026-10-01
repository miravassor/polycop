// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import os

/// Everything the window shows, and the work behind it.
///
/// One job at a time. Each recording becomes an entry kept on disk. The
/// engine and the decoder run off the main actor, and every result is
/// delivered back here. Each job has a number, so a job cancelled after a
/// newer one starts cannot overwrite state the newer job already set.
///
/// Holds the stored state and the helpers shared by the AppModel+*.swift
/// extensions, one file per concern: models, glossaries, the transcription
/// queue, repeat repair, editing, export, the library.
@Observable
final class AppModel {
    enum Stage: Equatable {
        case waiting
        case downloading(Double)
        case loading
        case decoding
        case transcribing(Double)
        case repairing(Double)
        case paused(Double)
        case stopping

        var isBusy: Bool { self != .waiting }

        /// Work actually under way, as opposed to waiting or paused.
        var isRunning: Bool {
            switch self {
            case .waiting, .paused: false
            case .downloading, .loading, .decoding, .transcribing, .repairing, .stopping: true
            }
        }
    }

    /// What the window shows: the pane for new transcriptions, or one entry.
    enum Pane: Hashable {
        case new
        case entry(Entry.ID)
    }

    // The setter of these is internal rather than private: extensions in the
    // other AppModel+*.swift files assign them directly.
    var stage = Stage.waiting {
        didSet { holdActivity(while: stage.isRunning) }
    }
    /// Every recording given to the app, newest first.
    var entries: [Entry] = []
    var folders: [TranscriptFolder] = []
    /// The entry being transcribed, or paused part way through.
    var running: Entry.ID?
    /// The entry whose repeats are being transcribed again. Kept apart from
    /// `running` because a repair works on an already complete transcript.
    /// Stopping it, or quitting, loses only the repair; the entry keeps its
    /// state instead of becoming a stopped transcription.
    var repairing: Entry.ID?
    /// The entry any work is on, whichever kind.
    var busyEntry: Entry.ID? { running ?? repairing }
    var pane = Pane.new {
        didSet {
            guard pane != oldValue else { return }
            rememberPlace(in: oldValue)
            // Leaving a transcript writes what was typed in it, and where it was left.
            savePending()
            player.stop()
            failure = nil
        }
    }
    /// The paragraph at the top of the transcript on screen, reported as the
    /// reader scrolls and kept with the entry only when it is left, so that
    /// scrolling writes nothing.
    @ObservationIgnored var readingParagraph: Int?
    private(set) var installed: Set<String> = []
    /// Whether Qwen3 Forced Aligner is installed, so that Qwen times sentences.
    private(set) var alignerInstalled = false
    var canAlignQwen: Bool {
        alignerInstalled && Memory.areLikelyToFit(ModelCatalog.qwen, ModelCatalog.qwenAligner)
    }
    private(set) var imported: [ModelStore.Imported] = []
    let player = Player()
    /// Where each course's remembered corrections are kept; tests use their own.
    var courseCorrectionsFolder = GlossaryStore.directory {
        didSet { readCourseCorrections = [:] }
    }
    /// Each course's corrections, read from disk once: every run of the course
    /// and the glossary editor ask for them.
    @ObservationIgnored var readCourseCorrections: [String: [CourseCorrection]] = [:]

    /// The file name of the chosen model. A name rather than a value, because
    /// the choice can be a catalogue entry or a file the user imported.
    var selected = ModelCatalog.recommended.id

    /// Off by default: silence removal can discard speech along with the silence.
    var skipsSilence = false
    /// The language spoken in the recordings that have not started.
    var language = "fr"
    /// Holds off idle sleep while a job runs. It cannot hold off the lid:
    /// closing a MacBook sleeps it whatever an application asks.
    var keepAwake = true {
        didSet {
            holdActivity(while: false)
            holdActivity(while: stage.isRunning)
        }
    }
    var failure: String?

    /// Shows an error a view ran into, such as a file panel that failed.
    func report(_ error: any Error) {
        failure = error.localizedDescription
    }
    /// A failure that belongs to one transcript rather than to the library, so
    /// that it cannot appear under another one after the list moves on.
    var entryFailure: EntryFailure?

    struct EntryFailure: Equatable {
        let id: Entry.ID
        let message: String
    }

    func failure(for id: Entry.ID) -> String? {
        entryFailure?.id == id ? entryFailure?.message : nil
    }

    /// A menu command cannot reach the state of a view, so it leaves a token
    /// here. The view that owns the sheet acts on a new one and clears it.
    var recordingsRequest: UUID?
    var folderRequest: UUID?
    var glossariesRequest: UUID?
    var transcriptImportRequest: UUID?
    var storageFailure: String?
    /// Records that could not be read when the library opened. Shown until the
    /// user has dealt with them, and never acted on by the app.
    private(set) var libraryWarning: String?
    /// Whether the list of folders could not be read. While it cannot, no
    /// folder is created, renamed or deleted, since a write would overwrite
    /// the only copy of the folder names.
    private(set) var foldersAreDamaged = false
    private(set) var isShuttingDown = false
    var hasUnsavedHistory: Bool { !unsavedHistory.isEmpty || !unsavedGlossaries.isEmpty }

    /// Course glossaries, and the one sent with the next recordings added.
    var glossaries: [Glossary] = []
    var glossaryName: String?

    var selectedCatalogue: Model? { ModelCatalog.model(selected) }
    /// A glossary only applies to a model that reads one.
    var glossaryApplies: Bool { selectedCatalogue?.readsGlossary ?? true }
    /// Silence removal only applies to an engine that does it.
    var silenceApplies: Bool { selectedCatalogue?.engine.skipsSilence ?? true }

    /// Recordings being transcribed or waiting their turn.
    var hasWork: Bool { running != nil || !waiting.isEmpty }

    /// The model the waiting recordings need, when it is not installed yet.
    /// Waiting for it is not a failure, since the model can still arrive.
    var missingModel: Model? {
        guard let next = nextInLine, !isInstalled(next.modelFile) else { return nil }
        return ModelCatalog.model(next.modelFile)
    }

    /// Recordings added and not yet transcribed, in the order they were added.
    var waiting: [Entry] { entries.filter { $0.state == .waiting }.sorted { $0.added < $1.added } }

    var nextInLine: Entry? { waiting.first { scheduled.contains($0.id) } }

    /// Whether a recording that waits or runs needs this model, so that
    /// deleting it cannot make a queued transcription fail later.
    func isNeeded(_ file: String) -> Bool {
        entries.contains {
            $0.modelFile == file && ($0.state == .waiting || $0.state == .running)
        }
    }

    /// Serves entries one after another without reloading the weights, and is
    /// released once none is waiting, and before the process exits: a live
    /// context at termination aborts in the framework's static teardown.
    var engine: (any TranscriptionEngine)?
    var engineFile: String?
    /// Whether the loaded engine last ran with silence removal. whisper.cpp
    /// resets its time mapping only when the detector runs, so a call without
    /// it on the same engine would remap its times with the previous table.
    var engineSkipsSilence: Bool?
    var engineAligns: Bool?
    var work: Task<Void, Never>?
    var job = 0
    var scheduled: Set<Entry.ID> = []
    /// Retries not started yet, which keep the settings of the job they repeat.
    var retries: Set<Entry.ID> = []
    var downloadingModel: Model?
    let history: URL
    /// Which models are installed, and how an engine opens.
    let engines: Engines
    var unsavedHistory: Set<Entry.ID> = []
    var unsavedGlossaries: [String: Glossary] = [:]
    /// Corrections already made, oldest first, so one can be stepped back. It
    /// lives as long as the app does: what is on disk is what was last seen.
    var corrections: [Entry.ID: [[Transcript.Paragraph]]] = [:]
    /// Entries typed into and not written yet, and the write waiting for a
    /// pause in the typing.
    @ObservationIgnored var pendingSaves: Set<Entry.ID> = []
    @ObservationIgnored var pendingSave: Task<Void, Never>?

    /// What a transcription needs to continue after a pause. It lives as long
    /// as the app does: quitting loses a paused job, by decision, and its entry
    /// keeps what the pause had decoded.
    struct Transcription {
        let id: Entry.ID
        var samples: [Float] = []
    }
    var paused: Transcription?
    var pausing = false
    var pausedAt = 0.0
    private var activity: NSObjectProtocol?

    init(history: URL = HistoryStore.directory, engines: Engines = .live) {
        self.history = history
        self.engines = engines
        refreshInstalled()
        selected = ModelCatalog.startingModel(installed: installed).id
        refreshGlossaries()
        let library = HistoryStore.all(in: history)
        entries = library.entries
        var damaged = library.damaged.count
        do {
            folders = try HistoryStore.folders(in: history)
        } catch {
            // The folder names could not be read. Left on disk rather than
            // written over, so nothing else is lost while the user decides
            // what to do; no folder can be changed until then.
            foldersAreDamaged = true
            damaged += 1
        }
        if damaged > 0 {
            libraryWarning = String(
                localized:
                    "\(damaged) file of your library could not be read. It has been left untouched in \(history.path(percentEncoded: false)). The rest of your transcripts are here."
            )
        }
        // A job cut short by quitting cannot resume: its audio is gone.
        for entry in entries where entry.state == .waiting || entry.state == .running {
            updateEntry(entry.id) { $0.state = .stopped }
        }
    }

    func refreshInstalled() {
        installed = engines.installed()
        alignerInstalled = ModelStore.isInstalled(ModelCatalog.qwenAligner)
        imported = ModelStore.imported()
        if selectedCatalogue == nil { selected = ModelCatalog.recommended.id }
    }

    func isInstalled(_ id: String) -> Bool {
        installed.contains(id)
    }

    func entry(_ id: Entry.ID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Whether this job is still the one under way.
    func isCurrent(_ number: Int) -> Bool { number == job && !isShuttingDown }

    func beginJob() -> Int {
        job += 1
        return job
    }

    /// Where the recording is, renewing the bookmark when macOS says it is
    /// stale. Read at the start of an operation, which is where a write to the
    /// record belongs.
    func recording(of entry: Entry) -> URL {
        let (url, stale) = entry.resolved()
        if stale { updateEntry(entry.id) { $0.relink(to: url) } }
        return url
    }

    /// Every change reaches the disk at once, so nothing waits on a save to
    /// survive quitting. Typing is the exception: encoding a whole transcript
    /// at each key made typing stutter, so it is written after a pause, and
    /// quitting writes what is left. A write that fails is kept in memory
    /// instead, and the queue waits until it can be retried.
    func updateEntry(
        _ id: Entry.ID, whileTyping: Bool = false, _ update: (inout Entry) -> Void
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let before = entries[index]
        update(&entries[index])
        guard entries[index] != before else { return }
        if whileTyping {
            saveAfterPause(id)
        } else {
            store(entries[index])
        }
    }

    private func saveAfterPause(_ id: Entry.ID) {
        pendingSaves.insert(id)
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.savePending()
        }
    }

    /// Writes the entries typed into since their last write.
    func savePending() {
        pendingSave?.cancel()
        pendingSave = nil
        for entry in entries where pendingSaves.contains(entry.id) {
            store(entry)
        }
    }

    func store(_ entry: Entry) {
        pendingSaves.remove(entry.id)
        do {
            try HistoryStore.write(entry, in: history)
            let recovered = unsavedHistory.remove(entry.id) != nil
            if !hasUnsavedHistory {
                storageFailure = nil
                if recovered { startNext() }
            }
        } catch {
            unsavedHistory.insert(entry.id)
            storageFailure = error.localizedDescription
        }
    }

    @discardableResult
    func retrySavingHistory() -> Bool {
        savePending()
        for glossary in Array(unsavedGlossaries.values) {
            try? saveGlossary(glossary)
        }
        for entry in entries where unsavedHistory.contains(entry.id) {
            store(entry)
        }
        if !hasUnsavedHistory { startNext() }
        return !hasUnsavedHistory
    }

    /// Called before the process exits. Freeing the context is what keeps the
    /// framework's static teardown from aborting.
    func shutDown() async {
        isShuttingDown = true
        scheduled.removeAll()
        downloadingModel = nil
        stage = .stopping
        player.stop()
        pausing = false
        paused = nil
        job += 1
        // Kept in the list as stopped, to transcribe again after the next launch.
        // Repairs are excluded, since their transcript is already complete.
        for entry in entries where entry.state == .waiting || entry.state == .running {
            updateEntry(entry.id) { $0.state = .stopped }
        }
        running = nil
        repairing = nil
        let stopping = work
        stopping?.cancel()
        _ = await stopping?.value
        work = nil
        // The last call on the engine's queue must have let go before the
        // context is freed, while the process is still alive to free it.
        await engine?.drain()
        releaseEngine()
        stage = .waiting
    }

    /// The user kept the window open after a failed final history write.
    func cancelTermination() {
        isShuttingDown = false
    }

    func releaseEngine() {
        engine = nil
        engineFile = nil
        engineSkipsSilence = nil
        engineAligns = nil
    }

    /// Held while work runs. Without it App Nap can slow a transcription whose
    /// window is hidden; with keep awake on, idle sleep is held off as well.
    private func holdActivity(while running: Bool) {
        if running, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: keepAwake ? .userInitiated : .userInitiatedAllowingIdleSystemSleep,
                reason: "Transcribing a lecture")
        } else if !running, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
    }
}
