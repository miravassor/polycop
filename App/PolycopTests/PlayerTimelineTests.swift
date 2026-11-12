// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

// A double click on the timeline shows the passage there: the paragraph that
// opens within a few points of it, otherwise the one being spoken.

@Test func aPointOfTheTimelineBelongsToTheParagraphOpeningOrSpokenThere() {
    let scale = TimelineScale(width: 404, duration: 400)
    let marks: [TimeInterval] = [0, 100, 200, 300]
    #expect(scale.paragraph(at: scale.offset(for: 200) - 3, among: marks) == 2)
    #expect(scale.paragraph(at: scale.offset(for: 250), among: marks) == 2)
    #expect(scale.paragraph(at: scale.offset(for: 399), among: marks) == 3)
    #expect(scale.paragraph(at: 10, among: []) == nil)
    // Before the first paragraph opens, it is still the first.
    #expect(scale.paragraph(at: scale.offset(for: 10), among: [50, 100]) == 0)
}

@Test func aPointOfTheTimelineIsTheTimeItIsDrawnAt() {
    let scale = TimelineScale(width: 404, duration: 400)
    #expect(scale.time(at: scale.offset(for: 150)) == 150)
    #expect(scale.time(at: -50) == 0)
    #expect(scale.time(at: 5000) == 400)
    #expect(TimelineScale(width: 0, duration: 400).time(at: 10) == 0)
}

// Both times of a recording read alike: the hours show in both or in neither.

@Test func thePlayersTimesShowHoursOnlyInARecordingThatHasAny() {
    #expect(PlayerBar.clock(700, of: 1640) == "11:40")
    #expect(PlayerBar.clock(1640, of: 1640) == "27:20")
    #expect(PlayerBar.clock(2000, of: 5450) == "0:33:20")
    #expect(PlayerBar.clock(5450, of: 5450) == "1:30:50")
    #expect(PlayerBar.clock(-5, of: 1640) == "0:00")
    // A position past an hour in a recording whose length is not known yet.
    #expect(PlayerBar.clock(4000, of: 0) == "1:06:40")
}
