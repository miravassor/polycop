// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import Polycop

/// Controls leave a playing picture once the pointer rests, but not a paused one,
/// nor while the pointer is on a button, so that the next click lands where aimed.
@MainActor
@Test(arguments: [
    (hovering: false, over: false, resting: false, playing: false, shows: false),
    (hovering: true, over: false, resting: false, playing: true, shows: true),
    (hovering: true, over: false, resting: true, playing: true, shows: false),
    (hovering: true, over: true, resting: true, playing: true, shows: true),
    (hovering: true, over: false, resting: true, playing: false, shows: true),
])
func videoControlsShowWhileTheyAreOfUse(
    hovering: Bool, over: Bool, resting: Bool, playing: Bool, shows: Bool
) {
    #expect(
        VideoTransport.shows(
            isHovering: hovering, isOverControl: over, isPointerResting: resting,
            isPlaying: playing) == shows)
}

@MainActor
@Test func videoControlsGrowWithThePictureWithinLimits() {
    #expect(VideoTransport.diameter(forWidth: 100) == 26)
    #expect(VideoTransport.diameter(forWidth: 360) == 36)
    #expect(VideoTransport.diameter(forWidth: 1000) == 44)
}
