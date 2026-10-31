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

extension AppModel {
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
