// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Testing

@testable import Polycop

/// The picture takes a click itself: anything drawn over it, as AVPlayerView
/// draws Live Text, would keep the click from playing or pausing.
@MainActor
@Test func aClickOnThePicturePlaysOrPauses() throws {
    let view = PictureView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
    var toggles = 0
    view.toggle = { toggles += 1 }
    let window = NSWindow(
        contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }

    let center = NSPoint(x: 80, y: 60)
    try #require(window.contentView?.hitTest(center) === view)
    // Sent to the view: a window that is not key, as under tests, keeps
    // its first click to itself.
    let click = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1))
    view.mouseDown(with: click)
    #expect(toggles == 1)
}

/// Copy Frame takes the picture at the time asked, at its own size.
@Test func aFrameIsTakenAtItsOwnSize() async throws {
    let video = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/formats/clip-video.mp4")
    let frame = try await Player.frame(of: video, at: 0.5)
    #expect(frame.width == 160)
    #expect(frame.height == 120)
}

/// While the video window is open, its controls may start playback; a window
/// macOS restores at launch, which no page asked for, closes at once.
@MainActor
@Test func theVideoWindowLetsItsControlsPlayWhileOpen() {
    let player = Player(defaults: MemoryDefaults())
    let video = VideoPresentation(player: player)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 160, height: 120), styleMask: [.titled],
        backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    defer { window.close() }

    video.windowAppeared(window)
    #expect(!window.isVisible)
    #expect(!video.isElsewhere)

    var opened = 0
    video.openWindow { opened += 1 }
    window.orderFront(nil)
    video.windowAppeared(window)
    #expect(opened == 1)
    #expect(video.isInWindow)
    #expect(player.followsOutsideControls)

    video.windowClosed()
    #expect(!video.isElsewhere)
    #expect(!player.followsOutsideControls)
}
