// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Writes and deletes records one after another on a queue of its own.
/// Encoding a three-hour lecture timed by word takes about 50 ms, too long to
/// spend on the main actor at every correction. One serial queue keeps the
/// order: the last write of an entry is the one left on disk, and a delete
/// comes after every write asked before it.
nonisolated final class HistoryWriter: Sendable {
    let folder: URL
    private let queue = DispatchQueue(
        label: "io.github.miravassor.Polycop.history", qos: .userInitiated)

    init(folder: URL) {
        self.folder = folder
    }

    /// Writes `entry` after the writes asked before it. `done` runs on the
    /// main queue, in the order the writes were asked.
    func write(
        _ entry: Entry, done: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        queue.async { [folder] in
            let result = Result { try HistoryStore.write(entry, in: folder) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    /// Deletes a record once the writes asked before it are done, so none of
    /// them puts it back. Waits, as removing is rare and must be known to work.
    func delete(_ id: Entry.ID) throws {
        try queue.sync { [folder] in try HistoryStore.delete(id, in: folder) }
    }

    /// Returns once every write asked so far is on disk and its `done` has
    /// run, as quitting needs before it answers.
    func finish() async {
        await queue.run {}
        // The completions were queued on the main queue before this resumes.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
