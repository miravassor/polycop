// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Equality-guarded cache of sidebar custom tags and per-folder flair summaries.
/// Owned by `AppModel` so transcript text edits do not re-scan the library or
/// notify observers whose flairs did not change.
@Observable
final class LibraryFlairCache {
    private(set) var custom: [TranscriptFlair] = []
    private(set) var folders: [UUID: [TranscriptFlair]] = [:]
    @ObservationIgnored private var suppressesSync = false

    func sync(_ entries: [Entry], _ libraryFolders: [TranscriptFolder]) {
        guard !suppressesSync else { return }
        refresh(entries, libraryFolders)
    }

    func withSync(
        deferred: Bool = true,
        entries: () -> [Entry],
        folders libraryFolders: () -> [TranscriptFolder],
        _ work: () -> Void
    ) {
        let wasSuppressed = suppressesSync
        suppressesSync = true
        defer {
            suppressesSync = wasSuppressed
            if deferred, !wasSuppressed { refresh(entries(), libraryFolders()) }
        }
        work()
    }

    private func refresh(_ entries: [Entry], _ libraryFolders: [TranscriptFolder]) {
        let parents = Dictionary(
            libraryFolders.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first }
        )
        var tags: [TranscriptFlair] = []
        var byFolder: [UUID: [TranscriptFlair]] = [:]
        for entry in entries {
            guard let entryFlairs = entry.flairs, !entryFlairs.isEmpty else { continue }
            for flair in entryFlairs where flair.kind == nil && !flair.title.isEmpty {
                Self.appendUnique(flair, to: &tags)
            }
            guard let folderID = entry.folderID, let parentID = parents[folderID] else { continue }
            for flair in entryFlairs {
                Self.appendUnique(flair, to: &byFolder[folderID, default: []])
                if let parentID {
                    Self.appendUnique(flair, to: &byFolder[parentID, default: []])
                }
            }
        }
        let nextCustom = tags.sorted(by: TranscriptFlair.areInDisplayOrder)
        if nextCustom != custom { custom = nextCustom }
        let nextFolders = byFolder.mapValues { $0.sorted(by: TranscriptFlair.areInDisplayOrder) }
        if nextFolders != folders { folders = nextFolders }
    }

    private static func appendUnique(
        _ flair: TranscriptFlair, to target: inout [TranscriptFlair]
    ) {
        if !target.contains(where: { $0.matchesIdentity(of: flair) }) {
            target.append(flair)
        }
    }
}

// MARK: Nested folders, pins, flairs, and sidebar search

extension AppModel {
    func folder(_ id: UUID) -> TranscriptFolder? {
        folders.first { $0.id == id }
    }

    var rootFolders: [TranscriptFolder] {
        folders.filter { $0.parentID == nil }
    }

    func subfolders(of parentID: UUID) -> [TranscriptFolder] {
        folders.filter { $0.parentID == parentID }
    }

    func canAddSubfolder(to folderID: UUID) -> Bool {
        folders.contains { $0.id == folderID && $0.parentID == nil }
    }

    func revealFolder(_ id: UUID) {
        layout.showsFolders = true
        layout.openFolders.insert(id)
        if let parentID = folder(id)?.parentID {
            layout.openFolders.insert(parentID)
        }
    }

    func folderPath(of folderID: UUID?) -> String? {
        guard let folderID, let target = folder(folderID) else { return nil }
        if let parentID = target.parentID, let parent = folder(parentID) {
            return "\(parent.name) / \(target.name)"
        }
        return target.name
    }

    func setPinned(_ ids: [Entry.ID], to isPinned: Bool) {
        guard !isShuttingDown else { return }
        if isPinned, !ids.isEmpty { layout.showsPinned = true }
        let value: Bool? = isPinned ? true : nil
        for id in ids { updateEntry(id) { $0.isPinned = value } }
    }

    func withFlairSync(deferred: Bool = true, _ work: () -> Void) {
        flairCache.withSync(deferred: deferred, entries: { entries }, folders: { folders }, work)
    }

    func toggleFlair(_ flair: TranscriptFlair, on ids: [Entry.ID]) {
        guard !isShuttingDown else { return }
        let existing = ids.compactMap { entry($0) }
        guard !existing.isEmpty else { return }
        let removes = existing.allSatisfy {
            $0.flairs?.contains { $0.matchesIdentity(of: flair) } == true
        }
        withFlairSync {
            for id in existing.map(\.id) {
                updateEntry(id) { entry in
                    var current = entry.flairs ?? []
                    if removes {
                        current.removeAll { $0.matchesIdentity(of: flair) }
                    } else {
                        current = appending(flair, to: current)
                    }
                    entry.flairs = current.isEmpty ? nil : current
                }
            }
        }
    }

    func addCustomTag(named rawTitle: String, color: FolderColor, to ids: [Entry.ID]) {
        guard !isShuttingDown else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let tag = TranscriptFlair(title: title, color: color)
        let targetSet = Set(ids)
        withFlairSync {
            for item in entries {
                let hasMatchingTag = item.flairs?.contains { $0.matchesIdentity(of: tag) } == true
                guard targetSet.contains(item.id) || hasMatchingTag else { continue }
                updateEntry(item.id) { entry in
                    var current = entry.flairs ?? []
                    current.removeAll { $0.matchesIdentity(of: tag) }
                    current.append(tag)
                    entry.flairs = current
                }
            }
        }
    }

    func clearFlairs(on ids: [Entry.ID]) {
        guard !isShuttingDown else { return }
        withFlairSync {
            for id in ids { updateEntry(id) { $0.flairs = nil } }
        }
    }

    private var trimmedSearchQuery: String {
        layout.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isFilteringLibrary: Bool {
        layout.filter != .all || !trimmedSearchQuery.isEmpty
    }

    var pinnedEntries: [Entry] {
        layout.sort.sorted(entries.filter { $0.isPinned == true && matchesLibraryFilter($0) })
    }

    /// Deduplicated flairs inside `folderID` and any subfolders for collapsed folder rows.
    func collapsedFolderFlairs(in folderID: UUID) -> [TranscriptFlair] {
        isFolderExpanded(folderID) ? [] : (folderFlairs[folderID] ?? [])
    }

    func isFolderExpanded(_ folderID: UUID) -> Bool {
        if isFilteringLibrary,
            hasVisibleContents(in: folderID)
                || subfolders(of: folderID).contains(where: { shouldShowFolder($0.id) })
        {
            return true
        }
        return layout.openFolders.contains(folderID)
    }

    func setFolderExpanded(_ folderID: UUID, to isExpanded: Bool) {
        guard !isFilteringLibrary else { return }
        if isExpanded {
            layout.openFolders.insert(folderID)
        } else {
            layout.openFolders.remove(folderID)
        }
    }

    private var visibleExpandedFolders: [UUID] {
        guard isFilteringLibrary || layout.showsFolders else { return [] }
        var ids: [UUID] = []
        for root in rootFolders where shouldShowFolder(root.id) && isFolderExpanded(root.id) {
            for subfolder in subfolders(of: root.id)
            where shouldShowFolder(subfolder.id) && isFolderExpanded(subfolder.id) {
                ids.append(subfolder.id)
            }
            ids.append(root.id)
        }
        return ids
    }

    var visibleEntryOrder: [Entry.ID] {
        var ordered = (isFilteringLibrary || layout.showsPinned) ? pinnedEntries.map(\.id) : []
        if isFilteringLibrary || layout.showsUnfiled {
            ordered.append(contentsOf: entries(in: nil).map(\.id))
        }
        for folderID in visibleExpandedFolders {
            ordered.append(contentsOf: entries(in: folderID).map(\.id))
        }
        return ordered
    }

    var visibleSelectablePanes: Set<Pane> {
        var panes = Set(visibleEntryOrder.map(Pane.entry))
        if isFilteringLibrary || layout.showsUnfiled {
            if !visibleUnidentifiedFiles.isEmpty { panes.insert(.unidentifiedFiles) }
            panes.formUnion(visibleUnavailable(in: nil).map { .unavailable($0.id) })
        }
        for folderID in visibleExpandedFolders {
            panes.formUnion(visibleUnavailable(in: folderID).map { .unavailable($0.id) })
        }
        return panes
    }

    func hasPinnedEntries(in folderID: UUID?) -> Bool {
        let known = folderID == nil ? Set(folders.map(\.id)) : []
        return entries.contains {
            $0.isPinned == true && belongs($0.folderID, to: folderID, known: known)
        }
    }

    func visibleUnavailable(in folderID: UUID?) -> [UnavailableRecord] {
        let records = unavailable(in: folderID)
        guard isFilteringLibrary else { return records }
        return records.filter { matchesUnavailableFilter($0) }
    }

    var visibleRecentlyDeleted: [Entry] {
        guard isFilteringLibrary else { return recentlyDeleted }
        return recentlyDeleted.filter { matchesLibraryFilter($0) }
    }

    var visibleRemovedUnavailable: [UnavailableRecord] {
        let removed = unavailable.filter { $0.removed != nil }
        guard isFilteringLibrary else { return removed }
        return removed.filter { matchesUnavailableFilter($0) }
    }

    private func matchesUnavailableFilter(_ record: UnavailableRecord) -> Bool {
        let query = trimmedSearchQuery
        switch layout.filter {
        case .all:
            break
        case .color(let color):
            guard folderColors(of: record.folderID).contains(color) else { return false }
        case .pinned, .unreviewed, .flair, .tag:
            return false
        }
        guard !query.isEmpty else { return true }
        if let name = record.name, name.localizedStandardContains(query) { return true }
        if let path = folderPath(of: record.folderID), path.localizedStandardContains(query) {
            return true
        }
        return false
    }

    var visibleUnidentifiedFiles: [URL] {
        let files = unidentifiedFiles
        guard isFilteringLibrary else { return files }
        guard layout.filter == .all else { return [] }
        let query = trimmedSearchQuery
        guard !query.isEmpty else { return files }
        return files.filter { $0.lastPathComponent.localizedStandardContains(query) }
    }

    func hasVisibleContents(in folderID: UUID) -> Bool {
        hasEntries(in: folderID)
            || !visibleUnavailable(in: folderID).isEmpty
            || subfolders(of: folderID).contains { hasVisibleContents(in: $0.id) }
    }

    func shouldShowFolder(_ folderID: UUID) -> Bool {
        guard isFilteringLibrary else { return true }
        if hasVisibleContents(in: folderID) { return true }
        if subfolders(of: folderID).contains(where: { shouldShowFolder($0.id) }) {
            return true
        }
        let query = trimmedSearchQuery
        guard !query.isEmpty, layout.filter == .all, let target = folder(folderID) else {
            return false
        }
        return target.name.localizedStandardContains(query)
    }

    func matchesLibraryFilter(_ entry: Entry) -> Bool {
        guard matches(entry, filter: layout.filter) else { return false }
        let query = trimmedSearchQuery
        return query.isEmpty || matches(entry, query: query)
    }

    private func appending(
        _ flair: TranscriptFlair, to current: [TranscriptFlair]
    ) -> [TranscriptFlair] {
        var updated = current
        if flair.kind?.isStatus == true {
            updated.removeAll { $0.kind?.isStatus == true }
        } else if flair.kind == nil, flair.title.isEmpty {
            updated.removeAll { $0.kind == nil && $0.title.isEmpty }
        } else {
            updated.removeAll { $0.matchesIdentity(of: flair) }
        }
        updated.append(flair)
        return updated
    }

    private func matches(_ entry: Entry, filter: LibraryFilter) -> Bool {
        let flairs = entry.flairs ?? []
        switch filter {
        case .all: return true
        case .pinned: return entry.isPinned == true
        case .unreviewed: return !flairs.contains { $0.kind == .done }
        case .flair(let kind): return flairs.contains { $0.kind == kind }
        case .tag(let title):
            return flairs.contains {
                $0.kind == nil
                    && $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
            }
        case .color(let color):
            return flairs.contains { $0.color == color }
                || folderColors(of: entry.folderID).contains(color)
        }
    }

    private func folderColors(of folderID: UUID?) -> [FolderColor] {
        guard let folderID, let target = folder(folderID) else { return [] }
        let parentColor = target.parentID.flatMap(folder)?.color
        return [target.color, parentColor].compactMap { $0 }
    }

    private func matches(_ entry: Entry, query: String) -> Bool {
        if entry.name.localizedStandardContains(query) { return true }
        if let path = folderPath(of: entry.folderID), path.localizedStandardContains(query) {
            return true
        }
        return (entry.flairs ?? []).contains {
            $0.displayTitle.localizedStandardContains(query)
                || $0.color.title.localizedStandardContains(query)
        }
    }
}
