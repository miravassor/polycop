// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing

@testable import Polycop

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/clip-fr.wav")

/// Settings kept in memory for one test: a set value would leave a preferences
/// file behind, and a registered one is shared by every test running at once.
private typealias Settings = MemoryDefaults

/// Opens the synthetic clip and waits until its duration is known.
@MainActor
private func open(_ player: Player) async throws {
    player.play(clip, from: 0)
    for _ in 0..<100 where !(player.isOpen && player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(player.isOpen && player.duration > 3)
    // Heard by nobody: the suite runs beside people at work.
    #expect(player.isSilent)
}

/// A recording AVFoundation cannot play is decoded into a copy first. A click
/// meanwhile moves where it opens, rather than starting the decoding over.
@MainActor
@Test func aSecondClickWhilePreparingMovesTheStart() async throws {
    let ogg = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/formats/clip.ogg")
    let copies = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let player = Player(defaults: Settings(), copies: copies)
    defer {
        player.stop()
        try? FileManager.default.removeItem(at: copies)
    }

    player.play(ogg, from: 0)
    try #require(player.isPreparing)
    player.play(ogg, from: 2)
    #expect(player.isPreparing)

    for _ in 0..<100 where !(player.isOpen && player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(player.isOpen)
    // Opened at the second time, then playing: on a busy machine it may
    // already have moved on by the time this reads it.
    #expect(player.position >= 2)
}

/// Sleep or headphones going away while a copy is being decoded pause what
/// was asked: the recording opens where it was asked, without playing.
@MainActor
@Test func anInterruptionWhilePreparingOpensPaused() async throws {
    let ogg = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/formats/clip.ogg")
    let copies = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let player = Player(defaults: Settings(), copies: copies)
    defer {
        player.stop()
        try? FileManager.default.removeItem(at: copies)
    }

    player.play(ogg, from: 1)
    try #require(player.isPreparing)
    player.pause()

    for _ in 0..<100 where !player.isOpen {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(player.isOpen)
    #expect(!player.isPlaying)
    #expect(player.position == 1)

    player.play(ogg, from: 1)
    #expect(player.isPlaying)
}

/// Leaving a transcript stops playback. Coming back plays the copy already
/// decoded rather than decoding the whole recording again.
@MainActor
@Test func aDecodedCopyIsKeptForTheNextPlayback() async throws {
    let mkv = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/formats/clip.mkv")
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let player = Player(defaults: Settings(), copies: folder)
    defer {
        player.discardCopy()
        try? FileManager.default.removeItem(at: folder)
    }

    var copies: [Player.KeptCopy] = []
    for _ in 0..<2 {
        player.play(mkv, from: 0)
        for _ in 0..<100 where !(player.isOpen && player.duration > 0) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(player.isOpen)
        player.stop()
        copies.append(try #require(player.keptCopy))
    }
    let kept = copies[0]
    #expect(copies[1] == kept)
    #expect(FileManager.default.fileExists(atPath: kept.file.path(percentEncoded: false)))
    #expect(kept.recording == mkv)

    player.discardCopy()
    #expect(!FileManager.default.fileExists(atPath: kept.file.path(percentEncoded: false)))
}

/// After a jump, the position shown never goes back to where playback was
/// while the audio is still moving to the new place: the word highlight and
/// the timeline went back for a moment before reaching it.
@MainActor
@Test func aJumpNeverShowsTheOldPositionAgain() async throws {
    let player = Player(defaults: Settings())
    defer { player.stop() }
    try await open(player)
    try await Task.sleep(for: .milliseconds(300))

    for target in [2.5, 0.5, 3.0] {
        player.seek(to: target)
        var lowest = player.position
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(10))
            lowest = min(lowest, player.position)
        }
        #expect(lowest >= target)
    }
}

@MainActor
@Test func resumingStepsBackSoTheSentenceIsHeardAgain() async throws {
    let settings = Settings()
    let player = Player(defaults: settings)
    defer { player.stop() }
    try await open(player)

    player.seek(to: 3)
    player.toggle()
    player.toggle()
    #expect(player.isPlaying)
    #expect(player.position == 3 - Player.defaultResumeRewind)

    // Moved while paused: playback resumes exactly where the user chose.
    player.toggle()
    player.seek(to: 3)
    player.toggle()
    #expect(player.position == 3)

    player.seek(to: 3)
    player.toggle()
    settings.values[Player.resumeRewindKey] = 0.0
    player.toggle()
    #expect(player.position == 3)
}

@MainActor
@Test func typingPausesPlaybackUnlessTheSettingIsOff() async throws {
    let settings = Settings()
    let player = Player(defaults: settings)
    defer { player.stop() }
    try await open(player)
    #expect(player.isPlaying)

    player.pauseForTyping()
    #expect(!player.isPlaying)

    player.toggle()
    settings.values[Player.pausesWhileTypingKey] = false
    player.pauseForTyping()
    #expect(player.isPlaying)
}

/// Playback that typing paused resumes once typing stops. Playback the user
/// paused, a command given meanwhile, or a delay set to never keeps it paused.
@MainActor
@Test func playbackResumesOnceTypingStops() async throws {
    let settings = Settings()
    settings.values[Player.resumeAfterTypingKey] = 0.2
    let player = Player(defaults: settings)
    defer { player.stop() }
    try await open(player)

    player.pauseForTyping()
    #expect(!player.isPlaying)
    for _ in 0..<100 where !player.isPlaying {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(player.isPlaying)

    // What must not happen is waited for over twice the delay.
    player.toggle()
    player.pauseForTyping()
    try await Task.sleep(for: .milliseconds(500))
    #expect(!player.isPlaying)

    player.toggle()
    player.pauseForTyping()
    player.seek(to: 1)
    player.pauseForTyping()
    try await Task.sleep(for: .milliseconds(500))
    #expect(!player.isPlaying)

    player.toggle()
    player.pauseForTyping()
    player.pause()
    try await Task.sleep(for: .milliseconds(500))
    #expect(!player.isPlaying)

    settings.values[Player.resumeAfterTypingKey] = 0.0
    player.toggle()
    player.pauseForTyping()
    try await Task.sleep(for: .milliseconds(500))
    #expect(!player.isPlaying)
}

/// Sleep and a departed output pause playback. Each test posts on a center of
/// its own and leaves the real audio devices alone, so tests running at once
/// never pause one another's players.
@MainActor
struct InterruptionTests {
    /// It also keeps paused what typing was about to resume, so playback never
    /// comes back by itself after the Mac woke or the headphones left.
    @Test func anInterruptionPausesPlaybackAndCancelsAResumeAfterTyping() async throws {
        let settings = Settings()
        settings.values[Player.resumeAfterTypingKey] = 0.2
        let player = Player(defaults: settings)
        let interruptions = PlaybackInterruptions(
            player: player, center: NotificationCenter(), watchesOutput: false)
        defer { player.stop() }
        try await open(player)
        #expect(player.isPlaying)

        interruptions.interrupt()
        #expect(!player.isPlaying)

        // Resuming works as any resume.
        player.toggle()
        #expect(player.isPlaying)

        player.pauseForTyping()
        interruptions.interrupt()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!player.isPlaying)
    }

    @Test func theMacGoingToSleepPausesPlayback() async throws {
        let center = NotificationCenter()
        let player = Player(defaults: Settings())
        var interruptions: PlaybackInterruptions? = PlaybackInterruptions(
            player: player, center: center, watchesOutput: false)
        defer { player.stop() }
        try await open(player)
        try #require(player.isPlaying)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<100 where player.isPlaying {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!player.isPlaying)

        // Once the observer is gone, sleep no longer touches the player.
        withExtendedLifetime(interruptions) {}
        interruptions = nil
        player.toggle()
        try #require(player.isPlaying)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.isPlaying)
    }

    /// As Music does: headphones that leave pause playback; headphones plugged
    /// in, or another output chosen, take it over.
    @Test func onlyAnOutputThatWentAwayPauses() {
        #expect(PlaybackInterruptions.wentAway(7, devices: [1, 2]))
        #expect(!PlaybackInterruptions.wentAway(7, devices: [1, 7, 9]))
        #expect(!PlaybackInterruptions.wentAway(nil, devices: [1]))
    }
}
