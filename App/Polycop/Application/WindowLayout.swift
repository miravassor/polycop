// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// How the reader left the window, remembered across launches. Here rather
/// than in scene storage, which macOS restores only along with the window, and
/// by default it closes windows for good when the app quits.
@Observable
final class WindowLayout {
    static let showsLibraryKey = "showsLibrary"
    static let showsInspectorKey = "showsInspector"
    static let libraryWidthKey = "libraryWidth"
    static let inspectorWidthKey = "inspectorWidth"
    static let openFoldersKey = "openFolders"
    static let showsPinnedKey = "showsPinned"
    static let showsUnfiledKey = "showsUnfiled"
    static let showsFoldersKey = "showsFolders"
    static let showsRecentlyDeletedKey = "showsRecentlyDeleted"
    static let librarySortKey = "librarySort"

    var showsLibrary: Bool {
        didSet { defaults.set(showsLibrary, forKey: Self.showsLibraryKey) }
    }
    var showsInspector: Bool {
        didSet { defaults.set(showsInspector, forKey: Self.showsInspectorKey) }
    }
    var libraryWidth: Double {
        didSet { defaults.set(libraryWidth, forKey: Self.libraryWidthKey) }
    }
    /// The same on every page, since each has an inspector of its own.
    var inspectorWidth: Double {
        didSet { defaults.set(inspectorWidth, forKey: Self.inspectorWidthKey) }
    }
    /// The library's folders showing what they hold.
    var openFolders: Set<UUID> {
        didSet { defaults.set(openFolders.map(\.uuidString), forKey: Self.openFoldersKey) }
    }
    /// Whether the sidebar's Pinned section is expanded.
    var showsPinned: Bool {
        didSet { defaults.set(showsPinned, forKey: Self.showsPinnedKey) }
    }
    /// Whether the sidebar's Unfiled section is expanded.
    var showsUnfiled: Bool {
        didSet { defaults.set(showsUnfiled, forKey: Self.showsUnfiledKey) }
    }
    /// Whether the sidebar's Folders section is expanded.
    var showsFolders: Bool {
        didSet { defaults.set(showsFolders, forKey: Self.showsFoldersKey) }
    }
    /// Whether the sidebar's Recently Deleted section is expanded.
    var showsRecentlyDeleted: Bool {
        didSet { defaults.set(showsRecentlyDeleted, forKey: Self.showsRecentlyDeletedKey) }
    }
    /// How transcripts in folders and outside them are ordered.
    var sort: LibrarySort {
        didSet { defaults.set(sort.rawValue, forKey: Self.librarySortKey) }
    }
    /// Transient sidebar filter, reset on launch so nothing stays hidden by surprise.
    var filter: LibraryFilter = .all
    var searchQuery = ""

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        showsLibrary = defaults.object(forKey: Self.showsLibraryKey) as? Bool ?? true
        showsInspector = defaults.object(forKey: Self.showsInspectorKey) as? Bool ?? true
        libraryWidth =
            defaults.object(forKey: Self.libraryWidthKey) as? Double
            ?? Double(ContentView.idealLibraryWidth)
        inspectorWidth =
            defaults.object(forKey: Self.inspectorWidthKey) as? Double
            ?? Double(EntryView.idealInspectorWidth)
        openFolders = Set(
            (defaults.stringArray(forKey: Self.openFoldersKey) ?? [])
                .compactMap(UUID.init(uuidString:)))
        showsPinned = defaults.object(forKey: Self.showsPinnedKey) as? Bool ?? true
        showsUnfiled = defaults.object(forKey: Self.showsUnfiledKey) as? Bool ?? true
        showsFolders = defaults.object(forKey: Self.showsFoldersKey) as? Bool ?? true
        showsRecentlyDeleted =
            defaults.object(forKey: Self.showsRecentlyDeletedKey) as? Bool ?? true
        sort =
            defaults.string(forKey: Self.librarySortKey)
            .flatMap(LibrarySort.init(rawValue:)) ?? .newestFirst
    }
}

/// How transcripts are ordered inside each folder and outside them.
nonisolated enum LibrarySort: String, Sendable {
    case newestFirst
    case oldestFirst
    case name

    /// Whether `first` appears before `second` in the sidebar.
    func areInIncreasingOrder(_ first: LibraryItem, _ second: LibraryItem) -> Bool {
        switch self {
        case .newestFirst:
            if first.added != second.added { return first.added > second.added }
        case .oldestFirst:
            if first.added != second.added { return first.added < second.added }
        case .name:
            let order = first.name.localizedStandardCompare(second.name)
            if order != .orderedSame { return order == .orderedAscending }
            if first.added != second.added { return first.added > second.added }
        }
        return first.id.uuidString < second.id.uuidString
    }

    func sorted(_ items: [LibraryItem]) -> [LibraryItem] {
        items.sorted(by: areInIncreasingOrder)
    }
}

/// Filters what the sidebar lists without changing saved transcript assignments.
nonisolated enum LibraryFilter: Hashable, Sendable {
    case all
    case pinned
    case unreviewed
    case flair(TranscriptFlair.Kind)
    case tag(String)
    case color(FolderColor)

    var title: String {
        switch self {
        case .all: String(localized: "All Transcripts")
        case .pinned: String(localized: "Pinned")
        case .unreviewed: String(localized: "Unreviewed")
        case .flair(let kind): kind.title
        case .tag(let title): title
        case .color(let color): color.title
        }
    }
}
