// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: Editing and undo

extension AppModel {
    /// Plays an entry's recording from a point of its transcript.
    func replay(_ id: Entry.ID, from time: TimeInterval, leadIn: TimeInterval = 0.5) {
        guard !isShuttingDown, let entry = entry(id) else { return }
        player.play(recording(of: entry), from: max(0, time - leadIn))
    }

    /// Points a transcript at its recording again, after the user found it
    /// themselves. Nothing is transcribed again, and the text is untouched.
    func locateRecording(_ id: Entry.ID, at file: URL) {
        guard !isShuttingDown, id != busyEntry, entry(id) != nil else { return }
        guard file.isFileURL,
            (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else {
            entryFailure = EntryFailure(
                id: id, message: String(localized: "Choose the recording itself, not a folder."))
            return
        }
        if entryFailure?.id == id { entryFailure = nil }
        if pane == .entry(id) { player.stop() }
        updateEntry(id) { $0.relink(to: file) }
    }

    func edit(_ id: Entry.ID, paragraphAt index: Int, text: String) {
        guard id != busyEntry, !isShuttingDown, let entry = entry(id),
            entry.paragraphs.indices.contains(index), entry.paragraphs[index].text != text
        else { return }
        rememberCorrection(entry)
        updateEntry(id) { $0.edit(paragraphAt: index, text: text) }
    }

    private func rememberCorrection(_ entry: Entry) {
        var steps = corrections[entry.id] ?? []
        steps.append(entry.paragraphs)
        // Bound undo snapshots; unchanged strings share their storage.
        corrections[entry.id] = steps.suffix(200)
    }

    func toggleReview(_ id: Entry.ID, paragraphAt index: Int) {
        guard id != busyEntry, !isShuttingDown, let entry = entry(id),
            entry.paragraphs.indices.contains(index)
        else { return }
        updateEntry(id) { $0.toggleReview(paragraphAt: index) }
    }

    func canUndo(_ id: Entry.ID) -> Bool { !(corrections[id] ?? []).isEmpty }

    /// Steps one correction back, as far as the text the engine wrote.
    func undo(_ id: Entry.ID) {
        guard id != busyEntry, !isShuttingDown, var steps = corrections[id],
            let previous = steps.popLast()
        else { return }
        corrections[id] = steps
        updateEntry(id) { entry in
            entry.paragraphs = previous
            entry.isEdited = previous != entry.original
            entry.isSaved = false
        }
    }

    /// Throws every correction away and shows the transcript as it came out of
    /// the engine. The recording and the exports already written are untouched.
    func revert(_ id: Entry.ID) {
        guard id != busyEntry, !isShuttingDown, let entry = entry(id), entry.isEdited else {
            return
        }
        rememberCorrection(entry)
        updateEntry(id) { entry in
            entry.paragraphs = entry.original
            entry.isEdited = false
            entry.isSaved = false
        }
    }

    /// A second transcript of the same recording, to correct it another way
    /// without losing the first. Nothing is transcribed again.
    @discardableResult
    func duplicate(_ id: Entry.ID) -> Entry.ID? {
        guard !isShuttingDown, id != busyEntry, let entry = entry(id),
            entry.state != .waiting, entry.state != .running
        else { return nil }
        let copy = entry.duplicated(among: Set(entries.map(\.name)))
        entries.insert(copy, at: 0)
        store(copy)
        return copy.id
    }

    /// Refused while corrections can be stepped back: rebuilding the
    /// paragraphs would discard them.
    func canPutBackCredits(of entry: Entry) -> Bool {
        entry.id != busyEntry && !entry.isEdited && !canUndo(entry.id)
    }

    func putBackCredits(_ id: Entry.ID) {
        guard !isShuttingDown, let entry = entry(id), canPutBackCredits(of: entry) else { return }
        var restored = false
        updateEntry(id) { restored = $0.putBackCredits() }
        // The paragraphs are rebuilt around the lines that came back, so the
        // corrections recorded against the old ones no longer fit. A refusal
        // changes nothing and keeps them.
        if restored { corrections[id] = nil }
    }

    func setSubtitles(_ on: Bool, for id: Entry.ID) {
        guard !isShuttingDown else { return }
        updateEntry(id) {
            $0.subtitles = on && $0.timesSentences
            $0.isSaved = false
        }
    }
}
