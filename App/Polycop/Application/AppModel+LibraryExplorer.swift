// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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

    func toggleFlair(_ flair: TranscriptFlair, on ids: [Entry.ID]) {
        guard !isShuttingDown else { return }
        let existing = ids.compactMap { entry($0) }
        guard !existing.isEmpty else { return }
        let removes = existing.allSatisfy {
            $0.flairs?.contains { $0.matchesIdentity(of: flair) } == true
        }
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

    func addCustomTag(named rawTitle: String, color: FolderColor, to ids: [Entry.ID]) {
        guard !isShuttingDown else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let tag = TranscriptFlair(title: title, color: color)
        let targetSet = Set(ids)
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

    func clearFlairs(on ids: [Entry.ID]) {
        guard !isShuttingDown else { return }
        for id in ids { updateEntry(id) { $0.flairs = nil } }
    }

    /// Returns sorted unique custom tags present across `entries`.
    static func customFlairs(in entries: [Entry]) -> [TranscriptFlair] {
        var tags: [TranscriptFlair] = []
        for entry in entries {
            let matching = (entry.flairs ?? []).filter { $0.kind == nil && !$0.title.isEmpty }
            appendUniqueFlairs(matching, to: &tags)
        }
        return tags.sorted(by: TranscriptFlair.areInDisplayOrder)
    }

    static func changedFlairs(
        _ entries: [Entry], _ current: [TranscriptFlair]
    ) -> [TranscriptFlair]? {
        let next = customFlairs(in: entries)
        return next == current ? nil : next
    }

    static func folderFlairs(
        in entries: [Entry], folders: [TranscriptFolder]
    ) -> [UUID: [TranscriptFlair]] {
        let parents = Dictionary(
            folders.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first }
        )
        var collected: [UUID: [TranscriptFlair]] = [:]
        for entry in entries {
            guard let folderID = entry.folderID, let parentID = parents[folderID],
                let entryFlairs = entry.flairs, !entryFlairs.isEmpty
            else { continue }
            appendUniqueFlairs(entryFlairs, to: &collected[folderID, default: []])
            if let parentID {
                appendUniqueFlairs(entryFlairs, to: &collected[parentID, default: []])
            }
        }
        return collected.mapValues { $0.sorted(by: TranscriptFlair.areInDisplayOrder) }
    }

    private static func appendUniqueFlairs(
        _ source: [TranscriptFlair], to target: inout [TranscriptFlair]
    ) {
        for flair in source where !target.contains(where: { $0.matchesIdentity(of: flair) }) {
            target.append(flair)
        }
    }

    static func changedFolderFlairs(
        _ entries: [Entry], _ folders: [TranscriptFolder], _ current: [UUID: [TranscriptFlair]]
    ) -> [UUID: [TranscriptFlair]]? {
        let next = folderFlairs(in: entries, folders: folders)
        return next == current ? nil : next
    }

    func syncFlairCaches() {
        if let tags = Self.changedFlairs(entries, customFlairs) { customFlairs = tags }
        syncFolderFlairs()
    }

    func syncFolderFlairs() {
        if let next = Self.changedFolderFlairs(entries, folders, folderFlairs) {
            folderFlairs = next
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
        guard !isFolderExpanded(folderID) else { return [] }
        guard isFilteringLibrary else { return folderFlairs[folderID] ?? [] }
        let children = subfolders(of: folderID)
        var collected: [TranscriptFlair] = []
        for entry in entries where matchesLibraryFilter(entry) {
            guard let entryFolder = entry.folderID,
                entryFolder == folderID || children.contains(where: { $0.id == entryFolder }),
                let entryFlairs = entry.flairs
            else { continue }
            Self.appendUniqueFlairs(entryFlairs, to: &collected)
        }
        return collected.sorted(by: TranscriptFlair.areInDisplayOrder)
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
