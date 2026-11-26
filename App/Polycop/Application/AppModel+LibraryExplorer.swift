// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: Nested folders, pins, flairs, and sidebar search

extension AppModel {
    /// Per-record sidebar facts and flair summaries, kept in sync on changes.
    func libraryItem(_ id: Entry.ID) -> LibraryItem? { library.item(id) }
    var customFlairs: [TranscriptFlair] { library.customFlairs }
    var folderFlairs: [UUID: [TranscriptFlair]] { library.folderFlairs }

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
        withLibrarySync {
            for id in ids { updateEntry(id) { $0.isPinned = value } }
        }
    }

    func withLibrarySync(_ work: () -> Void) {
        library.withSync(entries: { entries }, folders: { folders }, work)
    }

    func toggleFlair(_ flair: TranscriptFlair, on ids: [Entry.ID]) {
        guard !isShuttingDown else { return }
        let existing = ids.compactMap { entry($0) }
        guard !existing.isEmpty else { return }
        let removes = existing.allSatisfy {
            $0.flairs?.contains { $0.matchesIdentity(of: flair) } == true
        }
        withLibrarySync {
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
        withLibrarySync {
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
        withLibrarySync {
            for id in ids { updateEntry(id) { $0.flairs = nil } }
        }
    }

    private var trimmedSearchQuery: String {
        layout.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isFilteringLibrary: Bool {
        layout.filter != .all || !trimmedSearchQuery.isEmpty
    }

    var pinnedEntries: [LibraryItem] {
        layout.sort.sorted(library.items.filter { $0.isPinned && matchesLibraryFilter($0) })
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
        return library.items.contains {
            $0.isPinned && belongs($0.folderID, to: folderID, known: known)
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
        matchesLibraryFilter(LibraryItem(entry))
    }

    func matchesLibraryFilter(_ item: LibraryItem) -> Bool {
        guard matches(item, filter: layout.filter) else { return false }
        let query = trimmedSearchQuery
        return query.isEmpty || matches(item, query: query)
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

    private func matches(_ item: LibraryItem, filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: return true
        case .pinned: return item.isPinned
        case .unreviewed: return !item.flairs.contains { $0.kind == .done }
        case .flair(let kind): return item.flairs.contains { $0.kind == kind }
        case .tag(let title):
            return item.flairs.contains {
                $0.kind == nil
                    && $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
            }
        case .color(let color):
            return item.flairs.contains { $0.color == color }
                || folderColors(of: item.folderID).contains(color)
        }
    }

    private func folderColors(of folderID: UUID?) -> [FolderColor] {
        guard let folderID, let target = folder(folderID) else { return [] }
        let parentColor = target.parentID.flatMap(folder)?.color
        return [target.color, parentColor].compactMap { $0 }
    }

    private func matches(_ item: LibraryItem, query: String) -> Bool {
        if item.name.localizedStandardContains(query) { return true }
        if let path = folderPath(of: item.folderID), path.localizedStandardContains(query) {
            return true
        }
        return item.flairs.contains {
            $0.displayTitle.localizedStandardContains(query)
                || $0.color.title.localizedStandardContains(query)
        }
    }
}
