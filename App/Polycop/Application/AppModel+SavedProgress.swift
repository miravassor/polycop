// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// What the job under way has written, as last saved, so that a crash or a dead
/// battery costs a minute of it rather than all of it. It goes in each
/// write of the entry and stays out of `entries`: the page reacts to segments
/// with notices about a text it does not show yet, and a job's entry can still
/// be written for another reason, such as a rename, which must not lose it.
nonisolated struct SavedProgress {
    /// Short enough for a fast model, which can finish a long recording in a few
    /// minutes. A write costs little, off the main actor, though it grows with the
    /// text. Tests shorten this.
    var interval: Duration = .seconds(60)
    var id: Entry.ID?
    var segments: [Segment] = []

    /// More than the entry holds, which it stops being once the job publishes.
    func isAhead(of entry: Entry) -> Bool {
        id == entry.id && segments.count > entry.decoded.count
    }
}

extension AppModel {
    /// Saves what `written` returns at each interval, until cancelled or the
    /// job is no longer current.
    func saveProgress(
        of id: Entry.ID, job number: Int, written: @escaping @Sendable () -> [Segment]
    ) -> Task<Void, Never> {
        let interval = savedProgress.interval
        return Task { [weak self] in
            while (try? await Task.sleep(for: interval)) != nil {
                guard let self, isCurrent(number), let entry = entry(id) else { return }
                let segments = written()
                guard segments.count > max(entry.decoded.count, savedProgress.segments.count)
                else { continue }
                savedProgress.id = id
                savedProgress.segments = segments
                store(entry)
            }
        }
    }

    /// Runs as a job's task ends. Stop and quit invalidate the job, but its
    /// completed segments still belong here.
    func keepWhatAStopLeft(
        of id: Entry.ID, kept: [Segment], _ collected: [Segment], since started: Date
    ) {
        if entry(id)?.state == .stopped, !collected.isEmpty {
            updateEntry(id) { $0.publish(kept + collected, partial: true) }
            recordTimeSpent(since: started, on: id)
        }
        savedProgress = SavedProgress(interval: savedProgress.interval)
    }

    /// At launch, the jobs a crash or a dead battery cut short. Nothing starts
    /// on its own, least of all what may have caused the crash: each stops with
    /// what it saved as its text, as a stop would have left it. Also one forced
    /// to quit while stopping, which said so before writing its text.
    func stopJobsCutShort() {
        for entry in entries {
            let lostItsText =
                entry.state == .stopped && entry.paragraphs.isEmpty && !entry.decoded.isEmpty
            guard entry.state == .running || lostItsText else { continue }
            updateEntry(entry.id) {
                if !$0.decoded.isEmpty { $0.publish($0.decoded, partial: true) }
                $0.state = .stopped
            }
        }
    }
}
