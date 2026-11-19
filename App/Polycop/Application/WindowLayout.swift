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
        didSet {
            defaults.set(libraryWidth, forKey: Self.libraryWidthKey)
            guard !isSyncingWidth else { return }
            isSyncingWidth = true
            defer { isSyncingWidth = false }
            let matched = libraryWidth + Double(ContentView.libraryInset)
            if inspectorWidth != matched { inspectorWidth = matched }
        }
    }
    /// Paired with the library's width so both columns take the same width from
    /// the window's edges.
    var inspectorWidth: Double {
        didSet {
            defaults.set(inspectorWidth, forKey: Self.inspectorWidthKey)
            guard !isSyncingWidth else { return }
            isSyncingWidth = true
            defer { isSyncingWidth = false }
            let matched = inspectorWidth - Double(ContentView.libraryInset)
            if libraryWidth != matched { libraryWidth = matched }
        }
    }
    /// The library's folders showing what they hold.
    var openFolders: Set<UUID> {
        didSet { defaults.set(openFolders.map(\.uuidString), forKey: Self.openFoldersKey) }
    }
    /// How transcripts in folders and outside them are ordered.
    var sort: LibrarySort {
        didSet { defaults.set(sort.rawValue, forKey: Self.librarySortKey) }
    }

    static let defaultHeight: CGFloat = 880

    static var defaultWidth: CGFloat {
        ContentView.idealLibraryWidth
            + ContentView.libraryInset
            + EntryView.readingWidth(textSize: ReadingSettings.defaultTextSize)
            + 2 * Spacing.page
            + EntryView.idealInspectorWidth
    }

    /// Default centred window size with both sidebars matching horizontally
    /// (`idealLibraryWidth + libraryInset == idealInspectorWidth == 360 pt`).
    static var defaultSize: CGSize {
        CGSize(width: defaultWidth, height: defaultHeight)
    }

    static let singleSidebarWidth = Double(
        ContentView.idealLibraryWidth + ContentView.libraryInset + ContentView.pageMinimumWidth)
    private static let bothSidebarsWidth =
        singleSidebarWidth + Double(EntryView.idealInspectorWidth)

    /// Current content width of the window, used to fold sidebars when narrow
    /// without overwriting the reader's stored choices.
    var windowWidth: Double = .infinity {
        didSet {
            if windowWidth >= Self.bothSidebarsWidth || windowWidth < Self.singleSidebarWidth {
                prefersInspectorWhenNarrow = false
            }
        }
    }
    var isResettingSize = false
    private var prefersInspectorWhenNarrow = false

    /// Restores both sidebars to their symmetric default widths.
    func resetToDefaultSize() {
        prefersInspectorWhenNarrow = false
        showsLibrary = true
        showsInspector = true
        // Updating `libraryWidth` syncs `inspectorWidth` via `didSet`.
        libraryWidth = Double(ContentView.idealLibraryWidth)
    }

    /// Widest each open sidebar may stretch from the window's edge without
    /// pushing the center page below `ContentView.pageMinimumWidth`.
    var maxInspectorColumnWidth: CGFloat {
        guard windowWidth.isFinite else { return EntryView.inspectorWidths.upperBound }
        let available = CGFloat(windowWidth) - ContentView.pageMinimumWidth
        let visibleCount: CGFloat = isLibraryShown && isInspectorShown ? 2 : 1
        return min(
            EntryView.inspectorWidths.upperBound,
            max(EntryView.idealInspectorWidth, available / visibleCount)
        )
    }

    /// Matching library column ceiling inside the leading glass inset on macOS 26.
    var maxLibraryColumnWidth: CGFloat {
        max(ContentView.idealLibraryWidth, maxInspectorColumnWidth - ContentView.libraryInset)
    }

    /// Records a user drag of the library divider while ignoring transient
    /// window-narrowing clamps below the stored width.
    func recordLibraryWidth(_ measured: CGFloat) {
        let ceiling = maxLibraryColumnWidth
        guard
            shouldRecordColumnWidth(
                measured, shown: isLibraryShown, range: ContentView.libraryWidths,
                ceiling: ceiling, current: libraryWidth)
        else { return }
        libraryWidth = Double(measured)
    }

    /// Records a user drag of the inspector divider while ignoring transient
    /// window-narrowing clamps below the stored width.
    func recordInspectorWidth(_ measured: CGFloat) {
        let ceiling = maxInspectorColumnWidth
        guard
            shouldRecordColumnWidth(
                measured, shown: isInspectorShown, range: EntryView.inspectorWidths,
                ceiling: ceiling, current: inspectorWidth)
        else { return }
        inspectorWidth = Double(measured)
    }

    private func shouldRecordColumnWidth(
        _ measured: CGFloat, shown: Bool, range: ClosedRange<CGFloat>,
        ceiling: CGFloat, current: Double
    ) -> Bool {
        guard !isResettingSize, shown, range.contains(measured),
            measured < ceiling - 0.5 || current <= Double(ceiling) + 0.5,
            abs(Double(measured) - current) >= 0.5
        else { return false }
        return true
    }

    /// Whether the window has room for the library beside the page.
    var canShowLibrary: Bool {
        windowWidth >= Self.singleSidebarWidth
    }

    /// Whether the window has room for the inspector beside the page and, if
    /// shown, the library.
    var canShowInspector: Bool {
        if windowWidth >= Self.bothSidebarsWidth { return true }
        guard windowWidth >= Self.singleSidebarWidth else { return false }
        return !showsLibrary || prefersInspectorWhenNarrow
    }

    /// Whether the library is shown at the window's current width.
    var isLibraryShown: Bool {
        get {
            guard showsLibrary, canShowLibrary else { return false }
            if windowWidth < Self.bothSidebarsWidth, showsInspector, prefersInspectorWhenNarrow {
                return false
            }
            return true
        }
        set {
            // SwiftUI writes back what AppKit's split view shows once a column
            // has folded or opened, the folds decided here included: only a
            // change is the reader's choice, or a fold would be stored as one.
            guard newValue != isLibraryShown, canShowLibrary else { return }
            prefersInspectorWhenNarrow = false
            showsLibrary = newValue
        }
    }

    /// Whether the inspector is shown at the window's current width.
    var isInspectorShown: Bool {
        get { showsInspector && canShowInspector }
        set {
            // Only a change is the reader's choice, as for the library.
            guard newValue != isInspectorShown, windowWidth >= Self.singleSidebarWidth
            else { return }
            if newValue {
                if windowWidth < Self.bothSidebarsWidth, showsLibrary {
                    prefersInspectorWhenNarrow = true
                }
                showsInspector = true
            } else {
                prefersInspectorWhenNarrow = false
                showsInspector = false
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isSyncingWidth = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        showsLibrary = defaults.object(forKey: Self.showsLibraryKey) as? Bool ?? true
        showsInspector = defaults.object(forKey: Self.showsInspectorKey) as? Bool ?? true
        let storedLibrary = defaults.object(forKey: Self.libraryWidthKey) as? Double
        let storedInspector = defaults.object(forKey: Self.inspectorWidthKey) as? Double
        let inset = Double(ContentView.libraryInset)
        let widths = ContentView.libraryWidths
        let validWidths = Double(widths.lowerBound)...Double(widths.upperBound)
        if let storedLibrary, let storedInspector,
            abs(storedLibrary + inset - storedInspector) < 1.0,
            validWidths.contains(storedLibrary)
        {
            libraryWidth = storedLibrary
            inspectorWidth = storedLibrary + inset
        } else {
            let defaultLibrary = Double(ContentView.idealLibraryWidth)
            let defaultInspector = Double(EntryView.idealInspectorWidth)
            libraryWidth = defaultLibrary
            inspectorWidth = defaultInspector
            defaults.set(defaultLibrary, forKey: Self.libraryWidthKey)
            defaults.set(defaultInspector, forKey: Self.inspectorWidthKey)
        }
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

    func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted(by: areInIncreasingOrder)
    }
}
