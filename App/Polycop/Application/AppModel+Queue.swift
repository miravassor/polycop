// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the Start step of the New transcription page offers, from what waits
/// and what runs.
nonisolated enum StartAction: Equatable {
    /// Nothing waits.
    case nothing
    /// Recordings wait and nothing runs.
    case start(count: Int)
    /// Recordings were added while others run or a model downloads; they
    /// join the queue only when asked, with the settings on the page then.
    case addToQueue(count: Int)
    /// A recording runs, and none was added since.
    case showProgress(name: String, waiting: Int)
    /// Recordings wait, and starting waits for the library to be saved.
    case waitingForSave(count: Int)
}

/// What the page of a recording that has not started offers.
nonisolated enum WaitingStep: Equatable {
    /// The model it needs is downloading.
    case download
    /// In line behind the one running; `after` names it when this one is next.
    case turn(after: String?)
    /// Nothing runs, so Start begins the `count` recordings waiting.
    case start(count: Int)
    /// Others run, and it joins them when asked.
    case addToQueue
    /// Starting waits for the library to be saved.
    case save
}

extension AppModel.Stage {
    /// How far the step under way is, for the steps that can tell.
    var fraction: Double? {
        switch self {
        case .downloading(let fraction), .transcribing(let fraction),
            .repairing(let fraction), .paused(let fraction):
            fraction
        case .waiting, .loading, .decoding, .stopping: nil
        }
    }

    var isTranscribing: Bool { if case .transcribing = self { true } else { false } }
    var isPaused: Bool { if case .paused = self { true } else { false } }
    var isDownloading: Bool { if case .downloading = self { true } else { false } }
}

extension AppModel {
    /// Whether a recording waits for the model being downloaded, which it
    /// needs before it can start. The stage is read last: each library row
    /// asks, and a row that reads it is drawn again at every step of progress.
    func isWaitingForDownload(_ entry: Entry) -> Bool {
        entry.state == .waiting && downloadingModel?.id == entry.modelFile && stage.isDownloading
    }

    func waitingStep(for entry: Entry) -> WaitingStep? {
        guard entry.state == .waiting else { return nil }
        if isWaitingForDownload(entry) { return .download }
        if isScheduled(entry.id), stage.isBusy || busyEntry != nil {
            let isNext = nextInLine?.id == entry.id
            return .turn(after: isNext ? running.flatMap(self.entry)?.name : nil)
        }
        switch startAction {
        case .start(let count): return .start(count: count)
        case .addToQueue: return .addToQueue
        case .waitingForSave: return .save
        case .nothing, .showProgress: return nil
        }
    }

    /// Recordings added and not yet asked for.
    var unscheduled: [Entry] { waiting.filter { !isScheduled($0.id) } }

    var startAction: StartAction {
        if canStart { return .start(count: waiting.count) }
        if !isShuttingDown, stage.isBusy || busyEntry != nil, !unscheduled.isEmpty {
            return .addToQueue(count: unscheduled.count)
        }
        if let running, let entry = entry(running) {
            return .showProgress(name: entry.name, waiting: waiting.count)
        }
        if !waiting.isEmpty, hasUnsavedHistory { return .waitingForSave(count: waiting.count) }
        return .nothing
    }

    /// Whether a transcript that stopped part way can continue from there now.
    /// Continuing lays out the whole text again, which the user's corrections
    /// would not survive. It runs at once or not at all: waiting its turn, its
    /// text could be corrected in the meantime. The stage is read late, as a
    /// page reads this at every step of other work, and the corrections last, as
    /// they run over the whole text.
    func canResume(_ entry: Entry) -> Bool {
        entry.state == .stopped && !entry.decoded.isEmpty && entry.hasRecording
            && isInstalled(entry.modelFile) && !isShuttingDown && !hasUnsavedHistory
            && busyEntry == nil && nextInLine == nil && !stage.isBusy
            && canRebuildParagraphs(of: entry)
    }

    /// Continues a stopped transcript with the settings it was given, whatever
    /// the page holds now. Its samples are gone, so the recording is converted
    /// again.
    func resumeStopped(_ id: Entry.ID) {
        refreshInstalled()
        guard let entry = entry(id), canResume(entry) else { return }
        failure = nil
        updateEntry(id) { $0.state = .waiting }
        scheduled.insert(id)
        startNext()
    }

    /// Puts the recordings added since behind those running, with the settings
    /// on the page now, as Start would. The queue takes them in turn when the
    /// running one, or the model download, finishes.
    func addToQueue() {
        guard case .addToQueue = startAction else { return }
        failure = nil
        let added = unscheduled
        let (glossary, lost) = chosenGlossary()
        for entry in added {
            updateEntry(entry.id) {
                $0.adopt(
                    modelFile: selected, glossary: glossary, language: language,
                    skipsSilence: skipsSilence && silenceApplies)
            }
        }
        scheduled.formUnion(added.map(\.id))
        if let lost { failure = lostGlossary(lost) }
    }
}
