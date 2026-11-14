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
    /// How transcripts in folders and outside them are ordered.
    var sort: LibrarySort {
        didSet { defaults.set(sort.rawValue, forKey: Self.librarySortKey) }
    }

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
    func areInIncreasingOrder(_ first: Entry, _ second: Entry) -> Bool {
        switch self {
        case .newestFirst:
            first.added > second.added
        case .oldestFirst:
            first.added < second.added
        case .name:
            switch first.name.localizedStandardCompare(second.name) {
            case .orderedAscending:
                true
            case .orderedDescending:
                false
            case .orderedSame:
                first.added > second.added
            }
        }
    }

    func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted(by: areInIncreasingOrder)
    }
}
