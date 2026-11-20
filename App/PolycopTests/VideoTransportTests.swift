// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
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

/// Sizing SF Symbols through the font keeps play.fill's optical side bearings,
/// shifting the triangle's bounding box slightly right of the button's centre so
/// it reads centred in its circle; resizable().scaledToFit() drops those
/// bearings and leaves the triangle visibly to the left.
@MainActor
@Test func videoPlayGlyphKeepsItsOpticalCentering() throws {
    let view = VideoTransport(
        player: Player(defaults: MemoryDefaults()), diameter: 36, canSkip: true,
        overSkip: { _ in }
    )
    .frame(width: 240, height: 100)
    .background(.black)

    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 240, height: 100)
    let window = NSWindow(
        contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()

    let bitmap = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = hosting.bounds.size
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

    let offset = try playGlyphOffset(in: bitmap)
    #expect(offset.x > 1.0 && offset.x < 3.0)
    #expect(abs(offset.y) < 1.0)
}

/// Returns the centre of the play glyph's bounding box relative to the centre
/// of the 240x100 (2x) render, in points.
@MainActor
private func playGlyphOffset(in bitmap: NSBitmapImageRep) throws -> (x: Double, y: Double) {
    let centerX = Double(bitmap.pixelsWide - 1) / 2
    let centerY = Double(bitmap.pixelsHigh - 1) / 2
    // Sample inside the play circle, clear of the glyph, so the contrast check
    // does not depend on the button fill matching the outer black background.
    let fill = try #require(luminance(at: Int(centerX), y: Int(centerY) - 44, in: bitmap))
    var minX = bitmap.pixelsWide
    var maxX = -1
    var minY = bitmap.pixelsHigh
    var maxY = -1
    // Stay strictly inside the 52.2 px circle radius so a button rim never
    // enters the bounding box.
    let radius = 38
    for dy in -radius...radius {
        for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
            let x = Int(centerX) + dx
            let y = Int(centerY) + dy
            guard let pixel = luminance(at: x, y: y, in: bitmap), pixel - fill > 0.15 else {
                continue
            }
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }
    try #require(minX <= maxX && minY <= maxY)
    return (
        x: (Double(minX + maxX) / 2 - centerX) / 2,
        y: (Double(minY + maxY) / 2 - centerY) / 2
    )
}

@MainActor
private func luminance(at x: Int, y: Int, in bitmap: NSBitmapImageRep) -> Double? {
    guard let color = bitmap.colorAt(x: x, y: y) else { return nil }
    return (color.redComponent + color.greenComponent + color.blueComponent) / 3
}
