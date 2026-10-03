// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: Library and folders

extension AppModel {
    func addFolder() {
        guard !isShuttingDown else { return }
        folderRequest = UUID()
    }

    /// How long a removed transcript stays in Recently Deleted.
    static let keepsDeleted: TimeInterval = 30 * 24 * 60 * 60

    /// Takes an entry out of the list into Recently Deleted. One with no text
    /// yet, such as a recording still waiting, has nothing to recover and is
    /// deleted. Saved transcript files stay where they are. The entry under
    /// way is refused: stopping it is a decision of its own.
    func removeEntry(_ id: Entry.ID) {
        guard id != busyEntry, !isShuttingDown, var entry = entry(id) else { return }
        entry.removed = .now
        do {
            if entry.paragraphs.isEmpty {
                try historyWriter.delete(id)
            } else {
                try historyWriter.write(entry)
                recentlyDeleted.insert(entry, at: 0)
            }
            entries.removeAll { $0.id == id }
            unsavedHistory.remove(id)
            scheduled.remove(id)
            undoSteps[id] = nil
            pendingSaves.remove(id)
            if !hasUnsavedHistory { storageFailure = nil }
            if pane == .entry(id) { pane = .new }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Puts a transcript from Recently Deleted back in the library, in the
    /// folder it was in.
    func recoverEntry(_ id: Entry.ID) {
        guard !isShuttingDown, var entry = recentlyDeleted.first(where: { $0.id == id }) else {
            return
        }
        entry.removed = nil
        do {
            try historyWriter.write(entry)
            recentlyDeleted.removeAll { $0.id == id }
            entries.insert(
                entry, at: entries.firstIndex { $0.added < entry.added } ?? entries.endIndex)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Deletes the record of a transcript in Recently Deleted, for good.
    func deleteEntry(_ id: Entry.ID) {
        guard !isShuttingDown else { return }
        do {
            try historyWriter.delete(id)
            recentlyDeleted.removeAll { $0.id == id }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Deletes what has been in Recently Deleted for longer than it keeps
    /// transcripts. One that cannot be deleted now is tried again next launch.
    func deleteExpired(now: Date = .now) {
        for entry in recentlyDeleted
        where now.timeIntervalSince(entry.removed ?? now) > Self.keepsDeleted {
            do {
                try historyWriter.delete(entry.id)
                recentlyDeleted.removeAll { $0.id == entry.id }
            } catch {
                Log.persistence.error(
                    "an expired transcript could not be deleted: \(error, privacy: .private)")
            }
        }
    }

    /// Takes several transcripts out of the library at once. The one being
    /// worked on stays, since stopping it is a decision of its own, and the
    /// user is told why that row remained.
    func removeEntries(_ ids: [Entry.ID]) {
        guard !isShuttingDown else { return }
        let busy = ids.contains { $0 == busyEntry }
        for id in ids where id != busyEntry { removeEntry(id) }
        if busy {
            failure = String(
                localized:
                    "The transcript being worked on was kept. Stop it first to remove it.")
        }
    }

    @discardableResult
    func createFolder(named name: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try refuseDamagedFolders()
        if let existing = folders.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return existing.id
        }
        let folder = TranscriptFolder(id: UUID(), name: name)
        let updated = folders + [folder]
        try HistoryStore.writeFolders(updated, in: history)
        folders = updated
        return folder.id
    }

    /// Refuses to write the list of folders while what is on disk cannot be
    /// read.
    private func refuseDamagedFolders() throws {
        guard foldersAreDamaged else { return }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// Refused while the list of folders cannot be read: no folder can be
    /// named then, and taking a transcript out of one would lose which folder
    /// it was in once the list is repaired.
    func moveEntry(_ id: Entry.ID, to folderID: UUID?) {
        guard !isShuttingDown, !foldersAreDamaged,
            folderID == nil || folders.contains(where: { $0.id == folderID })
        else { return }
        updateEntry(id) { $0.folderID = folderID }
    }

    /// Transcripts dragged onto a folder, or onto the unfiled section to leave
    /// one. What is carried is the identifier; a recording dragged in from the
    /// Finder carries a path instead, which matches no entry, and is refused.
    @discardableResult
    func moveEntries(_ identifiers: [String], to folderID: UUID?) -> Bool {
        guard !foldersAreDamaged else { return false }
        let moved =
            identifiers
            .compactMap(UUID.init(uuidString:))
            .filter { id in entries.contains { $0.id == id } }
        guard !moved.isEmpty else { return false }
        for id in moved { moveEntry(id, to: folderID) }
        return true
    }

    func renameFolder(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        try refuseDamagedFolders()
        guard
            !folders.contains(where: {
                $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            })
        else {
            throw CocoaError(.fileWriteFileExists)
        }
        var updated = folders
        updated[index].name = name
        try HistoryStore.writeFolders(updated, in: history)
        folders = updated
    }

    func removeFolder(_ id: UUID) throws {
        guard !entries.contains(where: { $0.folderID == id }) else { return }
        try refuseDamagedFolders()
        let updated = folders.filter { $0.id != id }
        try HistoryStore.writeFolders(updated, in: history)
        folders = updated
    }
}
