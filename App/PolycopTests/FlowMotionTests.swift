// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

// The flow along the played line eases between speeds, so play and pause
// start and stop it smoothly, and it never jumps when the speed changes.

private let start = Date(timeIntervalSinceReferenceDate: 1000)

@Test func theFlowEasesUpToItsSpeed() {
    var motion = FlowMotion()
    #expect(motion.distance(at: start) == 0)
    motion.change(to: 24, at: start)
    let half = FlowMotion.easing / 2
    #expect(abs(motion.speed(at: start.addingTimeInterval(half)) - 12) < 1e-9)
    #expect(motion.speed(at: start.addingTimeInterval(FlowMotion.easing + 1)) == 24)
    // Half the full speed on average while easing, then the full speed.
    let eased = 24 * FlowMotion.easing / 2
    #expect(abs(motion.distance(at: start.addingTimeInterval(FlowMotion.easing)) - eased) < 1e-9)
    #expect(
        abs(motion.distance(at: start.addingTimeInterval(FlowMotion.easing + 1)) - (eased + 24))
            < 1e-9)
}

@Test func aPauseSlowsTheFlowToRestWithoutAJump() {
    var motion = FlowMotion()
    motion.change(to: 24, at: start)
    let pause = start.addingTimeInterval(5)
    let before = motion.distance(at: pause)
    motion.change(to: 0, at: pause)
    #expect(abs(motion.distance(at: pause) - before) < 1e-9)
    let rest = before + 24 * FlowMotion.easing / 2
    #expect(abs(motion.distance(at: pause.addingTimeInterval(FlowMotion.easing)) - rest) < 1e-9)
    #expect(abs(motion.distance(at: pause.addingTimeInterval(60)) - rest) < 1e-9)
    #expect(motion.speed(at: pause.addingTimeInterval(60)) == 0)
}
