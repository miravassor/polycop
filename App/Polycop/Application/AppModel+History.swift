// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: Writing the library

extension AppModel {
    /// Every change is written at once, off the main actor, so nothing waits
    /// on a save to survive quitting. Typing is the exception: encoding a
    /// whole transcript at each key made typing stutter, so it is written
    /// after a pause, and quitting writes what is left. A write that fails is kept in memory
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

    /// Asks for the entry to be written. Its outcome arrives later, in the
    /// order writes were asked; `finishWrites()` waits for all of them.
    func store(_ entry: Entry) {
        pendingSaves.remove(entry.id)
        historyWriter.write(entry) { [weak self] result in
            self?.written(entry.id, result)
        }
    }

    /// A failed write keeps the entry in memory and holds the queue until a
    /// later write succeeds. A job may already run when the failure arrives:
    /// what it writes is kept and retried the same way.
    private func written(_ id: Entry.ID, _ result: Result<Void, any Error>) {
        // Removed since: nothing is left to save.
        guard entries.contains(where: { $0.id == id }) else {
            unsavedHistory.remove(id)
            return
        }
        switch result {
        case .success:
            let recovered = unsavedHistory.remove(id) != nil
            if !hasUnsavedHistory {
                storageFailure = nil
                if recovered { startNext() }
            }
        case .failure(let error):
            unsavedHistory.insert(id)
            storageFailure = error.localizedDescription
        }
    }

    /// Returns once every write asked so far has finished and been accounted for.
    func finishWrites() async {
        await historyWriter.finish()
    }

    @discardableResult
    func retrySavingHistory() async -> Bool {
        savePending()
        for glossary in Array(unsavedGlossaries.values) {
            try? saveGlossary(glossary)
        }
        for entry in entries where unsavedHistory.contains(entry.id) {
            store(entry)
        }
        await finishWrites()
        if !hasUnsavedHistory { startNext() }
        return !hasUnsavedHistory
    }
}
