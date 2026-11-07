// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// A section of a transcript's inspector, which the reader can fold.
nonisolated enum InspectorSection: String {
    case video, playback, export, warnings, details
}

/// How the reader has a transcript shown, remembered across launches. Here
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
    private(set) var foldedSections: Set<InspectorSection> {
        didSet { defaults.set(foldedSections.map(\.rawValue), forKey: Self.foldedSectionsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        textSize = defaults.object(forKey: Self.textSizeKey) as? Double ?? Self.defaultTextSize
        isComparing = defaults.bool(forKey: Self.isComparingKey)
        showsUncertainWords = defaults.object(forKey: Self.showsUncertainWordsKey) as? Bool ?? true
        foldedSections = Set(
            (defaults.stringArray(forKey: Self.foldedSectionsKey) ?? [])
                .compactMap(InspectorSection.init(rawValue:)))
    }

    func toggleFold(of section: InspectorSection) {
        foldedSections.formSymmetricDifference([section])
    }
}
