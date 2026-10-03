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
/// queue, repeat repair, editing, export, the library, failures.
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
    /// Transcripts removed from the library in the last `keepsDeleted`, most
    /// recent first, as Notes and Voice Memos keep them.
    var recentlyDeleted: [Entry] = []
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
    let player: Player
    /// Pauses playback for sleep and a change of output device, for as long as the model lives.
    @ObservationIgnored private let interruptions: PlaybackInterruptions
    /// The course glossaries, and each course's corrections beside them.
    let glossaryFolder: URL
    /// The downloaded models. Tests that transcribe read the user's, never
    /// writing to them.
    let modelFolder: URL
    /// Each course's corrections, read from disk once: every run of the course
    /// and the glossary editor ask for them.
    @ObservationIgnored var readCourseCorrections: [String: [CourseCorrection]] = [:]

    /// The file name of the chosen model. A name rather than a value, because
    /// the choice can be a catalogue entry or a file the user imported.
    var selected = ModelCatalog.recommended.id {
        didSet { defaults.set(selected, forKey: Self.selectedKey) }
    }

    /// Off by default: silence removal can discard speech along with the silence.
    var skipsSilence = false {
        didSet { defaults.set(skipsSilence, forKey: Self.skipsSilenceKey) }
    }
    /// The language spoken in the recordings that have not started.
    var language = "fr" {
        didSet { defaults.set(language, forKey: Self.languageKey) }
    }
    /// Holds off idle sleep while a job runs. It cannot hold off the lid:
    /// closing a MacBook sleeps it whatever an application asks. A preference,
    /// so it is remembered across launches.
    var keepAwake = true {
        didSet {
            defaults.set(keepAwake, forKey: Self.keepAwakeKey)
            holdActivity(while: false)
            holdActivity(while: stage.isRunning)
        }
    }
    /// The New Transcription settings and Keep awake are remembered across
    /// launches, as a student keeps the same model and course for weeks.
    static let keepAwakeKey = "keepAwake"
    static let selectedKey = "selectedModel"
    static let skipsSilenceKey = "skipsSilence"
    static let languageKey = "language"
    static let glossaryKey = "glossaryName"
    /// Where the preferences are kept; tests give settings of their own.
    @ObservationIgnored private let defaults: UserDefaults
    var failure: String?
    /// A failure that belongs to one transcript rather than to the library, so
    /// that it cannot appear under another one after the list moves on.
    var entryFailure: EntryFailure?

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
    var glossaryName: String? {
        didSet { defaults.set(glossaryName, forKey: Self.glossaryKey) }
    }

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
    var downloadingModel: Model?
    let history: URL
    /// Writes records off the main actor, in order.
    let historyWriter: HistoryWriter
    /// Which models are installed, and how an engine opens.
    let engines: Engines
    var unsavedHistory: Set<Entry.ID> = []
    var unsavedGlossaries: [String: Glossary] = [:]
    /// What each transcript was before its corrections, oldest first, so one
    /// can be stepped back. It lives as long as the app does: what is on disk
    /// is what was last seen.
    var undoSteps: [Entry.ID: [Entry.Revision]] = [:]
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

    /// The user's folders unless told otherwise: tests and a second copy of
    /// the app pass folders of their own.
    init(
        history: URL = HistoryStore.directory, glossaries: URL = GlossaryStore.directory,
        models: URL = ModelStore.directory, playbackCopies: URL = Player.copies,
        engines: Engines? = nil, defaults: UserDefaults = MemoryDefaults.forThisRun
    ) {
        self.defaults = defaults
        keepAwake = defaults.object(forKey: Self.keepAwakeKey) as? Bool ?? true
        skipsSilence = defaults.object(forKey: Self.skipsSilenceKey) as? Bool ?? false
        if let remembered = defaults.object(forKey: Self.languageKey) as? String,
            DecodingSettings.languages.contains(where: { $0.code == remembered })
        {
            language = remembered
        }
        self.history = history
        historyWriter = HistoryWriter(folder: history)
        glossaryFolder = glossaries
        modelFolder = models
        let player = Player(defaults: defaults, copies: playbackCopies)
        self.player = player
        interruptions = PlaybackInterruptions(player: player)
        self.engines = engines ?? .live(models: models)
        refreshInstalled()
        // What was chosen last, while it is still there; otherwise the
        // starting model and no glossary.
        if let remembered = defaults.object(forKey: Self.selectedKey) as? String,
            installed.contains(remembered)
        {
            selected = remembered
        } else {
            selected = ModelCatalog.startingModel(installed: installed).id
        }
        refreshGlossaries()
        if let remembered = defaults.object(forKey: Self.glossaryKey) as? String,
            self.glossaries.contains(where: { $0.name == remembered })
        {
            glossaryName = remembered
        }
        let library = HistoryStore.all(in: history)
        entries = library.entries.filter { $0.removed == nil }
        recentlyDeleted = library.entries.filter { $0.removed != nil }
            .sorted { ($0.removed ?? .distantPast) > ($1.removed ?? .distantPast) }
        deleteExpired()
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
        if damaged > 0 { libraryWarning = Self.warning(damaged: damaged, in: history) }
        // A job cut short by quitting cannot resume: its audio is gone.
        // Recordings that never started stay waiting for the next Start.
        for entry in entries where entry.state == .running {
            updateEntry(entry.id) { $0.state = .stopped }
        }
    }

    private static func warning(damaged: Int, in history: URL) -> String {
        let place = history.path(percentEncoded: false)
        return damaged == 1
            ? String(
                localized:
                    "1 file of your library could not be read. It has been left untouched in \(place). The rest of your transcripts are here."
            )
            : String(
                localized:
                    "\(damaged) files of your library could not be read. They have been left untouched in \(place). The rest of your transcripts are here."
            )
    }

    func refreshInstalled() {
        installed = engines.installed()
        alignerInstalled = ModelStore.isInstalled(ModelCatalog.qwenAligner, in: modelFolder)
        imported = ModelStore.imported(in: modelFolder)
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

    /// Called before the process exits. Freeing the context is what keeps the
    /// framework's static teardown from aborting.
    func shutDown() async {
        isShuttingDown = true
        // Typing first: the engine can take a while to stop, and the user may
        // force quit meanwhile.
        savePending()
        scheduled.removeAll()
        downloadingModel = nil
        stage = .stopping
        player.stop()
        player.discardCopy()
        pausing = false
        paused = nil
        job += 1
        // Kept in the list as stopped, to transcribe again after the next launch;
        // the recordings waiting stay in the queue. Repairs are excluded, since
        // their transcript is already complete.
        for entry in entries where entry.state == .running {
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
        // Writes asked so far, including those of the stopped job, reach the
        // disk before quitting.
        savePending()
        await finishWrites()
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
