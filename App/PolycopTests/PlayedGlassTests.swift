// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Testing

@testable import Polycop

// The played line and its knob are one outline, which keeps the knob round
// wherever it is, even where the line has no room yet to swell into it.

@available(macOS 26, *)
@Test(arguments: [(5.5, 13), (7.5, 13), (7.5, 17)] as [(CGFloat, CGFloat)])
func theKnobStaysRoundAllAlongTheLine(line: CGFloat, knob: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: 300, height: 28)
    let start: CGFloat = 7
    for step in 0...60 {
        let end = start + CGFloat(step) / 2
        // CGPath's test is exact, where SwiftUI's misses points near a curve.
        let path = PlayedShape(start: start, end: end, line: line, knob: knob).path(in: rect).cgPath
        let edge = knob / 2 - 0.25
        for degrees in stride(from: 0.0, to: 360, by: 10) {
            let angle = degrees * .pi / 180
            let point = CGPoint(x: end + edge * cos(angle), y: rect.midY + edge * sin(angle))
            #expect(path.contains(point), "knob at \(end) cut at \(degrees) degrees")
        }
        #expect(path.contains(CGPoint(x: start + 0.5, y: rect.midY)))
    }
}

// The flow along the played line eases between speeds, so play and pause
// start and stop it smoothly, and it never jumps when the speed changes.

private let moment = Date(timeIntervalSinceReferenceDate: 1000)

@Test func theFlowEasesUpToItsSpeed() {
    var motion = FlowMotion()
    #expect(motion.distance(at: moment) == 0)
    motion.change(to: 24, at: moment)
    let half = FlowMotion.easing / 2
    #expect(abs(motion.speed(at: moment.addingTimeInterval(half)) - 12) < 1e-9)
    #expect(motion.speed(at: moment.addingTimeInterval(FlowMotion.easing + 1)) == 24)
    // Half the full speed on average while easing, then the full speed.
    let eased = 24 * FlowMotion.easing / 2
    #expect(abs(motion.distance(at: moment.addingTimeInterval(FlowMotion.easing)) - eased) < 1e-9)
    #expect(
        abs(motion.distance(at: moment.addingTimeInterval(FlowMotion.easing + 1)) - (eased + 24))
            < 1e-9)
}

@Test func aPauseSlowsTheFlowToRestWithoutAJump() {
    var motion = FlowMotion()
    motion.change(to: 24, at: moment)
    let pause = moment.addingTimeInterval(5)
    let before = motion.distance(at: pause)
    motion.change(to: 0, at: pause)
    #expect(abs(motion.distance(at: pause) - before) < 1e-9)
    let rest = before + 24 * FlowMotion.easing / 2
    #expect(abs(motion.distance(at: pause.addingTimeInterval(FlowMotion.easing)) - rest) < 1e-9)
    #expect(abs(motion.distance(at: pause.addingTimeInterval(60)) - rest) < 1e-9)
    #expect(motion.speed(at: pause.addingTimeInterval(60)) == 0)
}
