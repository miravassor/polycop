// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: Editing and undo

extension AppModel {
    /// Plays an entry's recording from a point of its transcript.
    func replay(_ id: Entry.ID, from time: TimeInterval, leadIn: TimeInterval = 0.5) {
        guard !isShuttingDown, let entry = entry(id) else { return }
        player.play(recording(of: entry), from: max(0, time - leadIn))
    }

    /// Keeps where the reader was in the transcript of `pane`, read and heard,
    /// with the next save.
    func rememberPlace(in pane: Pane) {
        guard case .entry(let id) = pane else { return }
        let paragraph = readingParagraph
        let position = player.isOpen ? player.position : nil
        readingParagraph = nil
        updateEntry(id, whileTyping: true) { entry in
            if let paragraph { entry.readingParagraph = paragraph }
            if let position { entry.playbackPosition = position }
        }
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
        updateEntry(id, whileTyping: true) { $0.edit(paragraphAt: index, text: text) }
    }

    /// Replaces matches as one correction, so a single undo takes all of them back.
    func replace(_ id: Entry.ID, matches: [TranscriptSearch.Match], with replacement: String) {
        guard id != busyEntry, !isShuttingDown, let entry = entry(id) else { return }
        var replaced = entry
        guard replaced.replace(matches, with: replacement) else { return }
        rememberCorrection(entry)
        updateEntry(id) { $0 = replaced }
    }

    private func rememberCorrection(_ entry: Entry) {
        var steps = undoSteps[entry.id] ?? []
        steps.append(entry.revision)
        // Bound undo snapshots; unchanged strings share their storage.
        undoSteps[entry.id] = steps.suffix(200)
    }

    func toggleReview(_ id: Entry.ID, paragraphAt index: Int) {
        guard id != busyEntry, !isShuttingDown, let entry = entry(id),
            entry.paragraphs.indices.contains(index)
        else { return }
        updateEntry(id) { $0.toggleReview(paragraphAt: index) }
    }

    func canUndo(_ id: Entry.ID) -> Bool { !(undoSteps[id] ?? []).isEmpty }

    /// Steps one correction back, as far as the text the engine wrote. A
    /// revert stepped back brings back the course corrections it cleared.
    func undo(_ id: Entry.ID) {
        guard id != busyEntry, !isShuttingDown, var steps = undoSteps[id],
            let previous = steps.popLast()
        else { return }
        undoSteps[id] = steps
        updateEntry(id) { $0.restore(previous) }
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
            // Rebuilt paragraphs would otherwise take the corrections back.
            entry.courseCorrections = []
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

    /// Whether the paragraphs can be laid out again from what the engine
    /// wrote, as putting credits back and repairing repeats do. Refused while
    /// corrections can be stepped back, even after a revert: rebuilding the
    /// paragraphs would discard them. The course corrections, run over the
    /// whole text, are checked last.
    func canRebuildParagraphs(of entry: Entry) -> Bool {
        entry.id != busyEntry && !canUndo(entry.id) && entry.hasOnlyCourseCorrections
    }

    func putBackCredits(_ id: Entry.ID) {
        guard !isShuttingDown, let entry = entry(id), canRebuildParagraphs(of: entry) else {
            return
        }
        var restored = false
        updateEntry(id) { restored = $0.putBackCredits() }
        // The paragraphs are rebuilt around the lines that came back, so the
        // corrections recorded against the old ones no longer fit. A refusal
        // changes nothing and keeps them.
        if restored { undoSteps[id] = nil }
    }

    func setTextLayout(_ layout: Transcript.TextLayout, for id: Entry.ID) {
        guard !isShuttingDown else { return }
        updateEntry(id) {
            if layout == .word {
                $0.exportsWord = true
            } else {
                $0.exportsWord = nil
                $0.textLayout = layout
            }
            $0.isSaved = false
        }
    }

    func setRemovesHesitations(_ on: Bool, for id: Entry.ID) {
        guard !isShuttingDown else { return }
        updateEntry(id) {
            $0.removesHesitations = on
            $0.isSaved = false
        }
    }

    func setSubtitles(_ on: Bool, for id: Entry.ID) {
        guard !isShuttingDown else { return }
        updateEntry(id) {
            $0.subtitles = on && $0.timesSentences
            $0.isSaved = false
        }
    }
}
