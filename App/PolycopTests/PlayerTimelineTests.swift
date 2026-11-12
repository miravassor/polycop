// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

// The timeline stays a plain line until the pointer reaches for it: a lecture
// has a paragraph every few points of it.

@Test func noParagraphShowsOnTheTimelineAtRest() {
    let scale = TimelineScale(width: 400, duration: 5400)
    for x in stride(from: CGFloat(0), through: 400, by: 20) {
        #expect(scale.clarity(ofMarkAt: x, pointer: nil) == 0)
    }
}

@Test func paragraphsShowAroundThePointerAndFadeWithTheDistance() {
    let scale = TimelineScale(width: 400, duration: 5400)
    #expect(scale.clarity(ofMarkAt: 200, pointer: 200) == 1)
    let near = scale.clarity(ofMarkAt: 210, pointer: 200)
    let far = scale.clarity(ofMarkAt: 230, pointer: 200)
    #expect(near < 1 && far < near && far > 0)
    #expect(scale.clarity(ofMarkAt: 200 + TimelineScale.reach, pointer: 200) == 0)
    #expect(scale.clarity(ofMarkAt: 200 - TimelineScale.reach - 1, pointer: 200) == 0)
}

@Test func thePointerChoosesTheParagraphWhoseMarkItIsOn() {
    let scale = TimelineScale(width: 404, duration: 400)
    let marks: [TimeInterval] = [0, 100, 200, 300]
    #expect(scale.mark(near: scale.offset(for: 200) + 3, among: marks) == 2)
    #expect(scale.mark(near: scale.offset(for: 200) + 30, among: marks) == nil)
    #expect(scale.mark(near: 10, among: []) == nil)
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
}
