// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: Library and folders

extension AppModel {
    /// Where the recording is, renewing the bookmark when macOS says it is
    /// stale. Read at the start of an operation, which is where a write to the
    /// record belongs.
    func recording(of entry: Entry) -> URL {
        let (url, stale) = entry.resolved()
        if stale { updateEntry(entry.id) { $0.relink(to: url) } }
        return url
    }

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
            if pane == .entry(id) { openNewTranscription() }
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
        if var flairs = entry.flairs {
            let existing = customFlairs
            for index in flairs.indices where flairs[index].kind == nil {
                if let match = existing.first(where: { $0.matchesIdentity(of: flairs[index]) }) {
                    flairs[index] = match
                }
            }
            entry.flairs = flairs
        }
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
        withFlairSync {
            for id in ids where id != busyEntry { removeEntry(id) }
        }
        if busy {
            failure = String(
                localized:
                    "The transcript being worked on was kept. Stop it first to remove it.")
        }
    }

    @discardableResult
    func createFolder(named name: String, in parentID: UUID? = nil) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try refuseDamagedFolders()
        if let parentID, !canAddSubfolder(to: parentID) {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if let existing = folders.first(where: {
            $0.parentID == parentID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return existing.id
        }
        let folder = TranscriptFolder(id: UUID(), name: name, parentID: parentID)
        let updated = Self.sorted(folders + [folder])
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
    /// one. Refused when none is in the library, such as rows dragged from
    /// another copy of the app.
    @discardableResult
    func moveEntries(_ ids: [Entry.ID], to folderID: UUID?) -> Bool {
        guard !foldersAreDamaged else { return false }
        let moved = ids.filter { id in entries.contains { $0.id == id } }
        guard !moved.isEmpty else { return false }
        withFlairSync {
            for id in moved { moveEntry(id, to: folderID) }
        }
        return true
    }

    func renameFolder(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        try refuseDamagedFolders()
        let parentID = folders[index].parentID
        guard
            !folders.contains(where: {
                $0.id != id && $0.parentID == parentID
                    && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            })
        else {
            throw CocoaError(.fileWriteFileExists)
        }
        var updated = folders
        updated[index].name = name
        updated = Self.sorted(updated)
        try HistoryStore.writeFolders(updated, in: history)
        folders = updated
    }

    func setFolderColor(_ id: UUID, to color: FolderColor?) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        try refuseDamagedFolders()
        var updated = folders
        updated[index].color = color
        try HistoryStore.writeFolders(updated, in: history)
        folders = updated
    }

    /// The unpinned transcripts a place in the library holds: those of a folder,
    /// or with `nil` those in no folder this library knows, matching the active
    /// sidebar filter in the reader's chosen order.
    func entries(in folder: UUID?) -> [Entry] {
        let known = folder == nil ? Set(folders.map(\.id)) : []
        return layout.sort.sorted(
            entries.filter {
                $0.isPinned != true
                    && belongs($0.folderID, to: folder, known: known)
                    && matchesLibraryFilter($0)
            })
    }

    func hasEntries(in folder: UUID?) -> Bool {
        let known = folder == nil ? Set(folders.map(\.id)) : []
        return entries.contains {
            $0.isPinned != true
                && belongs($0.folderID, to: folder, known: known)
                && matchesLibraryFilter($0)
        }
    }

    /// The records a place in the library holds that this version cannot read:
    /// those of a folder, or with `nil` those in no folder this library knows, as
    /// for transcripts. What nothing identifies is in no folder.
    func unavailable(in folder: UUID?) -> [UnavailableRecord] {
        let known = folder == nil ? Set(folders.map(\.id)) : []
        return unavailable.filter { record in
            guard record.removed == nil, !record.isUnidentified else { return false }
            return belongs(record.folderID, to: folder, known: known)
        }
    }

    func belongs(_ folderID: UUID?, to folder: UUID?, known: Set<UUID>) -> Bool {
        if let folder { return folderID == folder }
        return folderID.map { !known.contains($0) } ?? true
    }

    /// Every file nothing identifies.
    var unidentifiedFiles: [URL] {
        unavailable.filter(\.isUnidentified).map(\.file)
    }

    /// Whether a folder lists anything, including subfolders and what cannot be
    /// read.
    func holdsTranscripts(_ folder: UUID) -> Bool {
        entries.contains { $0.folderID == folder }
            || !unavailable(in: folder).isEmpty
            || folders.contains { $0.parentID == folder }
    }

    func removeFolder(_ id: UUID) throws {
        guard !holdsTranscripts(id) else { return }
        try refuseDamagedFolders()
        let updated = folders.filter { $0.id != id }
        try HistoryStore.writeFolders(updated, in: history)
        folders = updated
        layout.openFolders.remove(id)
    }

    /// Folders in Finder-style alphabetical order within two levels: any folder
    /// whose parent does not exist or has a parent of its own becomes top-level.
    static func sorted(_ folders: [TranscriptFolder]) -> [TranscriptFolder] {
        let roots = Set(folders.filter { $0.parentID == nil }.map(\.id))
        return folders.map { folder in
            var copy = folder
            if let parentID = copy.parentID, parentID == copy.id || !roots.contains(parentID) {
                copy.parentID = nil
            }
            return copy
        }
        .sorted { first, second in
            let order = first.name.localizedStandardCompare(second.name)
            if order != .orderedSame { return order == .orderedAscending }
            return first.id.uuidString < second.id.uuidString
        }
    }
}
