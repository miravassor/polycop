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
