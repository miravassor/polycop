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
    #expect(settings.following == .page)
    #expect(settings.foldedSections.isEmpty)
    #expect(settings.showsLibrary)
    #expect(settings.showsInspector)
    #expect(settings.openFolders.isEmpty)
}

/// The keys are written out: changing one would lose what readers chose.
@MainActor
@Test func readingSettingsReadWhatEarlierVersionsStored() {
    let defaults = MemoryDefaults()
    defaults.set(18.0, forKey: "transcriptTextSize")
    defaults.set(true, forKey: "comparesOriginal")
    defaults.set(false, forKey: "showsUncertainWords")
    defaults.set("off", forKey: "followPlayback")
    let settings = ReadingSettings(defaults: defaults)
    #expect(settings.textSize == 18)
    #expect(settings.isComparing)
    #expect(!settings.showsUncertainWords)
    #expect(settings.following == .off)
}

/// The cursor setting of 0.4.0, when it was on, becomes the cursor choice, and
/// a choice made since is kept.
@MainActor
@Test func followingStartsFromTheEarlierCursorSetting() {
    let earlier = MemoryDefaults()
    earlier.set(true, forKey: "cursorFollowsPlayback")
    #expect(ReadingSettings(defaults: earlier).following == .cursor)

    let chosen = MemoryDefaults()
    chosen.set(true, forKey: "cursorFollowsPlayback")
    chosen.set("off", forKey: "followPlayback")
    #expect(ReadingSettings(defaults: chosen).following == .off)

    let left = MemoryDefaults()
    left.set(false, forKey: "cursorFollowsPlayback")
    #expect(ReadingSettings(defaults: left).following == .page)
}

@MainActor
@Test func readingSettingsAreRememberedForTheNextLaunch() {
    let defaults = MemoryDefaults()
    let settings = ReadingSettings(defaults: defaults)
    settings.textSize = 20
    settings.isComparing = true
    settings.showsUncertainWords = false
    settings.following = .cursor
    settings.showsLibrary = false
    settings.showsInspector = false
    let folder = UUID()
    settings.openFolders = [folder]
    settings.toggleFold(of: .warnings)
    settings.toggleFold(of: .video)
    settings.toggleFold(of: .details)
    settings.toggleFold(of: .details)
    let next = ReadingSettings(defaults: defaults)
    #expect(next.textSize == 20)
    #expect(next.isComparing)
    #expect(!next.showsUncertainWords)
    #expect(next.following == .cursor)
    #expect(!next.showsLibrary)
    #expect(!next.showsInspector)
    #expect(next.openFolders == [folder])
    #expect(next.foldedSections == [.warnings, .video])
}

/// The keys are written out, as above.
@MainActor
@Test func readingSettingsReadTheWindowsLayout() {
    let defaults = MemoryDefaults()
    let folder = UUID()
    defaults.set(false, forKey: "showsLibrary")
    defaults.set(false, forKey: "showsInspector")
    defaults.set([folder.uuidString, "not one"], forKey: "openFolders")
    let settings = ReadingSettings(defaults: defaults)
    #expect(!settings.showsLibrary)
    #expect(!settings.showsInspector)
    #expect(settings.openFolders == [folder])
}

/// The key and the names are written out, as above; a section a later version
/// removes is ignored.
@MainActor
@Test func readingSettingsReadTheFoldedSections() {
    let defaults = MemoryDefaults()
    defaults.set(
        ["video", "export", "warnings", "details", "gone"],
        forKey: "foldedInspectorSections")
    #expect(
        ReadingSettings(defaults: defaults).foldedSections
            == [.video, .export, .warnings, .details])
}
