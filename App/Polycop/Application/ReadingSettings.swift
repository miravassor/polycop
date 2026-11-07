// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// A section of a transcript's inspector, which the reader can fold.
nonisolated enum InspectorSection: String {
    case video, export, warnings, details
}

/// How the reader has the window and a transcript shown, remembered across
/// launches: macOS restores scene storage only with the window, which by default
/// it does not when the app quits. Here
/// rather than in `@AppStorage`: SwiftUI redoes a view that holds a setting, or
/// is given a binding made from one, at every update of its parent, while a
/// view reading a property here is redrawn only when that property changes.
@Observable
final class ReadingSettings {
    static let defaultTextSize = 13.0
    static let textSizeKey = "transcriptTextSize"
    static let isComparingKey = "comparesOriginal"
    static let showsUncertainWordsKey = "showsUncertainWords"
    static let foldedSectionsKey = "foldedInspectorSections"
    static let showsLibraryKey = "showsLibrary"
    static let showsInspectorKey = "showsInspector"
    static let openFoldersKey = "openFolders"

    var textSize: Double {
        didSet { defaults.set(textSize, forKey: Self.textSizeKey) }
    }
    /// Whether the original shows beside the text.
    var isComparing: Bool {
        didSet { defaults.set(isComparing, forKey: Self.isComparingKey) }
    }
    var showsUncertainWords: Bool {
        didSet { defaults.set(showsUncertainWords, forKey: Self.showsUncertainWordsKey) }
    }
    /// How the page keeps up with playback.
    var following: Following {
        didSet { defaults.set(following.rawValue, forKey: Following.key) }
    }
    private(set) var foldedSections: Set<InspectorSection> {
        didSet { defaults.set(foldedSections.map(\.rawValue), forKey: Self.foldedSectionsKey) }
    }

    var showsLibrary: Bool {
        didSet { defaults.set(showsLibrary, forKey: Self.showsLibraryKey) }
    }
    var showsInspector: Bool {
        didSet { defaults.set(showsInspector, forKey: Self.showsInspectorKey) }
    }
    /// The library's folders showing what they hold.
    var openFolders: Set<UUID> {
        didSet { defaults.set(openFolders.map(\.uuidString), forKey: Self.openFoldersKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        textSize = defaults.object(forKey: Self.textSizeKey) as? Double ?? Self.defaultTextSize
        isComparing = defaults.bool(forKey: Self.isComparingKey)
        showsUncertainWords = defaults.object(forKey: Self.showsUncertainWordsKey) as? Bool ?? true
        following = Following(stored: defaults)
        foldedSections = Set(
            (defaults.stringArray(forKey: Self.foldedSectionsKey) ?? [])
                .compactMap(InspectorSection.init(rawValue:)))
        showsLibrary = defaults.object(forKey: Self.showsLibraryKey) as? Bool ?? true
        showsInspector = defaults.object(forKey: Self.showsInspectorKey) as? Bool ?? true
        openFolders = Set(
            (defaults.stringArray(forKey: Self.openFoldersKey) ?? [])
                .compactMap(UUID.init(uuidString:)))
    }

    func toggleFold(of section: InspectorSection) {
        foldedSections.formSymmetricDifference([section])
    }
}
