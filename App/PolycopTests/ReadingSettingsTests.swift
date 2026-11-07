// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

@MainActor
@Test func readingSettingsStartFromWhatIsUsualForANewReader() {
    let settings = ReadingSettings(defaults: MemoryDefaults())
    #expect(settings.textSize == ReadingSettings.defaultTextSize)
    #expect(!settings.isComparing)
    #expect(settings.showsUncertainWords)
    #expect(settings.foldedSections.isEmpty)
}

/// The keys are written out: changing one would lose what readers chose.
@MainActor
@Test func readingSettingsReadWhatEarlierVersionsStored() {
    let defaults = MemoryDefaults()
    defaults.set(18.0, forKey: "transcriptTextSize")
    defaults.set(true, forKey: "comparesOriginal")
    defaults.set(false, forKey: "showsUncertainWords")
    let settings = ReadingSettings(defaults: defaults)
    #expect(settings.textSize == 18)
    #expect(settings.isComparing)
    #expect(!settings.showsUncertainWords)
}

@MainActor
@Test func readingSettingsAreRememberedForTheNextLaunch() {
    let defaults = MemoryDefaults()
    let settings = ReadingSettings(defaults: defaults)
    settings.textSize = 20
    settings.isComparing = true
    settings.showsUncertainWords = false
    settings.toggleFold(of: .warnings)
    settings.toggleFold(of: .video)
    settings.toggleFold(of: .details)
    settings.toggleFold(of: .details)
    let next = ReadingSettings(defaults: defaults)
    #expect(next.textSize == 20)
    #expect(next.isComparing)
    #expect(!next.showsUncertainWords)
    #expect(next.foldedSections == [.warnings, .video])
}

/// The key is written out, as above; a section a later version removes is ignored.
@MainActor
@Test func readingSettingsIgnoreASectionTheyDoNotKnow() {
    let defaults = MemoryDefaults()
    defaults.set(["video", "gone"], forKey: "foldedInspectorSections")
    #expect(ReadingSettings(defaults: defaults).foldedSections == [.video])
}
