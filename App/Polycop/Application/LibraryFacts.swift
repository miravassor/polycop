// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// What the sidebar, selection page, and library commands read of one
/// transcript. Corrections typed after the first edit leave every field equal,
/// so the library skips its body while editing.
nonisolated struct LibraryItem: Identifiable, Equatable, Sendable {
    var id: Entry.ID
    var name: String
    var added: Date
    var state: Entry.State
    var modelFile: String
    var folderID: UUID?
    var isPinned: Bool
    /// Sorted in display order once when derived so rows and menus read it directly.
    var flairs: [TranscriptFlair]
    var hasText: Bool
    var isEdited: Bool

    init(_ entry: Entry) {
        id = entry.id
        name = entry.name
        added = entry.added
        state = entry.state
        modelFile = entry.modelFile
        folderID = entry.folderID
        isPinned = entry.isPinned == true
        flairs = (entry.flairs ?? []).sorted(by: TranscriptFlair.areInDisplayOrder)
        hasText = !entry.paragraphs.isEmpty
        isEdited = entry.isEdited
    }
}

/// Per-record facts and flair summaries derived from `AppModel.entries` and
/// `AppModel.folders`, updated only when their values change so transcript text
/// edits do not notify the sidebar or menu commands.
@Observable
final class LibraryFacts {
    private(set) var items: [LibraryItem] = []
    private(set) var customFlairs: [TranscriptFlair] = []
    private(set) var folderFlairs: [UUID: [TranscriptFlair]] = [:]
    private(set) var hasWaiting = false
    /// Kept beside `items` for O(1) lookup; reads of `item(_:)` still touch
    /// `items` so SwiftUI observes updates to library items.
    @ObservationIgnored private var itemsByID: [Entry.ID: LibraryItem] = [:]
    @ObservationIgnored private var suppressesSync = false

    func item(_ id: Entry.ID) -> LibraryItem? {
        _ = items
        return itemsByID[id]
    }

    func sync(_ entries: [Entry], _ libraryFolders: [TranscriptFolder]) {
        guard !suppressesSync else { return }
        refresh(entries, libraryFolders)
    }

    func syncFolders(_ entries: [Entry], _ libraryFolders: [TranscriptFolder]) {
        guard !suppressesSync else { return }
        refreshFlairs(from: entries, folders: libraryFolders)
    }

    func withSync(
        entries: () -> [Entry],
        folders libraryFolders: () -> [TranscriptFolder],
        _ work: () -> Void
    ) {
        let wasSuppressed = suppressesSync
        suppressesSync = true
        defer {
            suppressesSync = wasSuppressed
            if !wasSuppressed { refresh(entries(), libraryFolders()) }
        }
        work()
    }

    /// Runs a single-record write to `entries[index]` and updates only that
    /// item's facts in O(1), returning without touching observed state when the
    /// record's `LibraryItem` is unchanged.
    func update(
        at index: Int, to updated: Entry, entries: () -> [Entry],
        folders libraryFolders: () -> [TranscriptFolder], _ write: () -> Void
    ) {
        let wasSuppressed = suppressesSync
        suppressesSync = true
        write()
        suppressesSync = wasSuppressed
        guard !wasSuppressed else { return }
        guard items.indices.contains(index), items[index].id == updated.id else {
            refresh(entries(), libraryFolders())
            return
        }
        applyUpdate(
            at: index, to: LibraryItem(updated), entries: entries, folders: libraryFolders)
    }

    private func applyUpdate(
        at index: Int, to next: LibraryItem, entries: () -> [Entry],
        folders libraryFolders: () -> [TranscriptFolder]
    ) {
        let previous = items[index]
        guard next != previous else { return }
        items[index] = next
        itemsByID[next.id] = next
        if next.state == .waiting {
            if !hasWaiting { hasWaiting = true }
        } else if previous.state == .waiting {
            let waiting = items.contains { $0.state == .waiting }
            if hasWaiting != waiting { hasWaiting = waiting }
        }
        if previous.flairs != next.flairs || previous.folderID != next.folderID {
            refreshFlairs(from: entries(), folders: libraryFolders())
        }
    }

    private func refresh(_ entries: [Entry], _ libraryFolders: [TranscriptFolder]) {
        let nextItems = entries.map(LibraryItem.init)
        if nextItems != items {
            items = nextItems
            itemsByID = Dictionary(uniqueKeysWithValues: nextItems.map { ($0.id, $0) })
        }
        let waiting = nextItems.contains { $0.state == .waiting }
        if hasWaiting != waiting { hasWaiting = waiting }
        refreshFlairs(from: entries, folders: libraryFolders)
    }

    private func refreshFlairs(
        from entries: [Entry], folders libraryFolders: [TranscriptFolder]
    ) {
        let parents = Dictionary(
            libraryFolders.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first }
        )
        var tags: [TranscriptFlair] = []
        var byFolder: [UUID: [TranscriptFlair]] = [:]
        for entry in entries {
            guard let flairs = entry.flairs, !flairs.isEmpty else { continue }
            Self.collectFlairs(
                flairs, folderID: entry.folderID, parents: parents, tags: &tags,
                byFolder: &byFolder)
        }
        let nextCustom = tags.sorted(by: TranscriptFlair.areInDisplayOrder)
        if nextCustom != customFlairs { customFlairs = nextCustom }
        let nextFolders = byFolder.mapValues { $0.sorted(by: TranscriptFlair.areInDisplayOrder) }
        if nextFolders != folderFlairs { folderFlairs = nextFolders }
    }

    private static func collectFlairs(
        _ flairs: [TranscriptFlair], folderID: UUID?, parents: [UUID: UUID?],
        tags: inout [TranscriptFlair], byFolder: inout [UUID: [TranscriptFlair]]
    ) {
        for flair in flairs where flair.kind == nil && !flair.title.isEmpty {
            appendUnique(flair, to: &tags)
        }
        guard let folderID, let parentID = parents[folderID] else { return }
        for flair in flairs {
            appendUnique(flair, to: &byFolder[folderID, default: []])
            if let parentID { appendUnique(flair, to: &byFolder[parentID, default: []]) }
        }
    }

    private static func appendUnique(
        _ flair: TranscriptFlair, to target: inout [TranscriptFlair]
    ) {
        if !target.contains(where: { $0.matchesIdentity(of: flair) }) {
            target.append(flair)
        }
    }
}
