// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AppKit
import Testing
import os

@testable import Polycop

private let clipVideo = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/formats/clip-video.mp4")

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
    let frame = try await Player.frame(of: clipVideo, at: 0.5)
    #expect(frame.width == 160)
    #expect(frame.height == 120)
}

/// While the picture fills the screen, the system's controls may start
/// playback; one window at a time, and closing it ends full screen.
@MainActor
@Test func fullScreenLetsItsControlsPlayWhileItLasts() async {
    let player = Player(defaults: MemoryDefaults())
    let video = VideoPresentation(player: player)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 160, height: 120), styleMask: [.titled],
        backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    // Kept from filling the screen under tests.
    window.collectionBehavior.insert(.fullScreenNone)
    var made = 0
    let make = {
        made += 1
        return window
    }

    video.fillScreen(with: make)
    video.fillScreen(with: make)
    #expect(made == 1)
    #expect(video.isFullScreen)
    #expect(player.followsOutsideControls)

    window.close()
    for _ in 0..<50 where video.isFullScreen { try? await Task.sleep(for: .milliseconds(20)) }
    #expect(!video.isFullScreen)
    #expect(!player.followsOutsideControls)
}

/// Guards its KVO-observable flag and notification counter with
/// `OSAllocatedUnfairLock` so tests can toggle readiness from a background
/// thread; the remaining properties are isolated to the main actor.
private final class FakePictureInPictureController: NSObject, PictureInPictureController,
    @unchecked Sendable
{
    private let possibleLock = OSAllocatedUnfairLock(initialState: false)
    private let notificationsLock = OSAllocatedUnfairLock(initialState: 0)

    @objc nonisolated dynamic var isPictureInPicturePossible: Bool {
        get { possibleLock.withLock { $0 } }
        set { possibleLock.withLock { $0 = newValue } }
    }

    @MainActor var isPictureInPictureActive = false
    @MainActor var startCount = 0
    @MainActor var observationCount = 0
    @MainActor var flipTrueBeforeObserving = false
    nonisolated var notifications: Int { notificationsLock.withLock { $0 } }

    func observePossible(_ onPossible: @escaping @Sendable () -> Void) -> NSKeyValueObservation {
        observationCount += 1
        if flipTrueBeforeObserving { isPictureInPicturePossible = true }
        let counter = notificationsLock
        return VideoPresentation.observePossible(self, at: \.isPictureInPicturePossible) {
            counter.withLock { $0 += 1 }
            onPossible()
        }
    }

    @MainActor func startPictureInPicture() { startCount += 1 }
    @MainActor func stopPictureInPicture() {}
}

@MainActor
private func preparedPlayer() async throws -> Player {
    let player = Player(defaults: MemoryDefaults())
    player.prepare(clipVideo, at: 0)
    for _ in 0..<200 where player.player == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(player.player != nil)
    return player
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// When Picture in Picture is already possible, it starts at once without
/// registering an observation.
@MainActor
@Test func pictureInPictureStartsImmediatelyWhenAlreadyPossible() async throws {
    let player = try await preparedPlayer()
    defer { player.stop() }
    let controller = FakePictureInPictureController()
    controller.isPictureInPicturePossible = true
    let layer = AVPlayerLayer()
    let video = VideoPresentation(player: player) { _, _ in controller }
    video.pictureLayer = layer

    video.startPictureInPicture()
    #expect(controller.startCount == 1)
    #expect(controller.observationCount == 0)
    #expect(layer.player === player.player)
}

/// Waiting for Picture in Picture reacts to KVO even from a background thread
/// and invalidates its observation once started.
@MainActor
@Test func pictureInPictureStartsWhenKVOBecomesPossibleFromBackgroundThread() async throws {
    let player = try await preparedPlayer()
    defer { player.stop() }
    let controller = FakePictureInPictureController()
    let layer = AVPlayerLayer()
    let video = VideoPresentation(player: player) { _, _ in controller }
    video.pictureLayer = layer

    video.startPictureInPicture()
    #expect(controller.startCount == 0)
    #expect(controller.observationCount == 1)
    #expect(layer.player === player.player)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            controller.isPictureInPicturePossible = true
            continuation.resume()
        }
    }
    try await waitUntil { controller.startCount == 1 }
    #expect(controller.startCount == 1)
    #expect(controller.notifications == 1)

    // Further flips after starting must not reach the invalidated observer.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            controller.isPictureInPicturePossible = false
            controller.isPictureInPicturePossible = true
            continuation.resume()
        }
    }
    await Task.yield()
    #expect(controller.notifications == 1)
    #expect(controller.startCount == 1)
}

/// If readiness flips true between the initial check and KVO registration,
/// the `.initial` delivery still starts Picture in Picture and cleans up.
@MainActor
@Test func pictureInPictureStartsWhenInitialKVOValueIsAlreadyTrue() async throws {
    let player = try await preparedPlayer()
    defer { player.stop() }
    let controller = FakePictureInPictureController()
    controller.flipTrueBeforeObserving = true
    let layer = AVPlayerLayer()
    let video = VideoPresentation(player: player) { _, _ in controller }
    video.pictureLayer = layer

    video.startPictureInPicture()
    try await waitUntil { controller.startCount == 1 }
    #expect(controller.startCount == 1)
    #expect(controller.notifications == 1)

    controller.isPictureInPicturePossible = false
    controller.isPictureInPicturePossible = true
    #expect(controller.notifications == 1)
}

/// Stopping while waiting invalidates the observation, detaches the layer,
/// and ignores any KVO hop queued before the stop or before a later start.
@MainActor
@Test func stoppingWhileWaitingForPictureInPictureCancelsObservationAndNeverStartsLate()
    async throws
{
    let player = try await preparedPlayer()
    defer { player.stop() }
    let first = FakePictureInPictureController()
    let second = FakePictureInPictureController()
    let third = FakePictureInPictureController()
    var controllers = [first, second, third]
    let layer = AVPlayerLayer()
    let video = VideoPresentation(player: player) { _, _ in controllers.removeFirst() }
    video.pictureLayer = layer

    video.startPictureInPicture()
    video.stopPictureInPicture()
    #expect(layer.player == nil)
    first.isPictureInPicturePossible = true
    #expect(first.notifications == 0)
    #expect(first.startCount == 0)

    // A KVO hop already queued for `second` must not start `second` or `third`.
    video.startPictureInPicture()
    second.isPictureInPicturePossible = true
    video.stopPictureInPicture()
    video.startPictureInPicture()
    await Task.yield()
    #expect(second.startCount == 0)
    #expect(third.startCount == 0)

    third.isPictureInPicturePossible = true
    try await waitUntil { third.startCount == 1 }
    #expect(second.startCount == 0)
    #expect(third.startCount == 1)
}

/// Switching or closing the player while waiting cancels the pending start.
@MainActor
@Test func changingPlayerWhileWaitingForPictureInPictureCancelsObservation() async throws {
    let player = try await preparedPlayer()
    defer { player.stop() }
    let controller = FakePictureInPictureController()
    let layer = AVPlayerLayer()
    let video = VideoPresentation(player: player) { _, _ in controller }
    video.pictureLayer = layer

    video.startPictureInPicture()
    video.playerChanged(to: nil)
    #expect(layer.player == nil)

    controller.isPictureInPicturePossible = true
    await Task.yield()
    #expect(controller.notifications == 0)
    #expect(controller.startCount == 0)
}

/// If Picture in Picture never becomes possible within the timeout, the
/// observation is invalidated, the layer is detached, and a later start works.
@MainActor
@Test func pictureInPictureTimeoutCleansUpObservationAndLayer() async throws {
    let player = try await preparedPlayer()
    defer { player.stop() }
    let timedOut = FakePictureInPictureController()
    let retry = FakePictureInPictureController()
    retry.isPictureInPicturePossible = true
    var controllers = [timedOut, retry]
    let layer = AVPlayerLayer()
    let video = VideoPresentation(
        player: player, pictureInPictureTimeout: .milliseconds(30)
    ) { _, _ in controllers.removeFirst() }
    video.pictureLayer = layer

    video.startPictureInPicture()
    try await waitUntil { layer.player == nil }
    #expect(layer.player == nil)
    #expect(timedOut.startCount == 0)

    timedOut.isPictureInPicturePossible = true
    await Task.yield()
    #expect(timedOut.notifications == 0)
    #expect(timedOut.startCount == 0)

    video.startPictureInPicture()
    #expect(retry.startCount == 1)
}

/// Releasing `VideoPresentation` while waiting cancels its KVO observation.
@MainActor
@Test func deallocatingVideoPresentationWhileWaitingCancelsObservation() async throws {
    let player = try await preparedPlayer()
    defer { player.stop() }
    let controller = FakePictureInPictureController()
    let layer = AVPlayerLayer()
    var video: VideoPresentation? = VideoPresentation(player: player) { _, _ in controller }
    video?.pictureLayer = layer
    video?.startPictureInPicture()
    #expect(controller.observationCount == 1)

    video = nil
    controller.isPictureInPicturePossible = true
    await Task.yield()
    #expect(controller.notifications == 0)
    #expect(controller.startCount == 0)
}

/// When Picture in Picture is unsupported, the layer does not stay attached.
@MainActor
@Test func unsupportedPictureInPictureDetachesLayer() async throws {
    let player = try await preparedPlayer()
    defer { player.stop() }
    let layer = AVPlayerLayer()
    let video = VideoPresentation(player: player) { _, _ in nil }
    video.pictureLayer = layer

    video.startPictureInPicture()
    #expect(layer.player == nil)
}
