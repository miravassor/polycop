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
private nonisolated final class Settings: UserDefaults, @unchecked Sendable {
    // Written by the test and read by the player, both on the main actor.
    var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
}

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
    let player = Player(defaults: Settings())
    defer { player.stop() }

    player.play(ogg, from: 0)
    try #require(player.isPreparing)
    player.play(ogg, from: 2)
    #expect(player.isPreparing)

    for _ in 0..<100 where !(player.isOpen && player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(player.isOpen)
    #expect(player.position == 2)
}

/// Leaving a transcript stops playback. Coming back plays the copy already
/// decoded rather than decoding the whole recording again.
@MainActor
@Test func aDecodedCopyIsKeptForTheNextPlayback() async throws {
    let mkv = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/formats/clip.mkv")
    let player = Player(defaults: Settings())
    defer { player.discardCopy() }

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

/// Both observers pause every player they watch, and a test posts the sleep
/// notification to the system-wide center, so these tests do not run at once.
@MainActor
@Suite(.serialized)
struct InterruptionTests {
    /// A device change cannot be staged in a test, so the observer's one method is
    /// called; the listener only calls it. It also keeps paused what typing was
    /// about to resume, so playback never moves to the speakers by itself.
    @Test func anInterruptionPausesPlaybackAndCancelsAResumeAfterTyping() async throws {
        let settings = Settings()
        settings.values[Player.resumeAfterTypingKey] = 0.2
        let player = Player(defaults: settings)
        let interruptions = PlaybackInterruptions(player: player)
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

    /// Posted on the workspace's own center, as the system does before sleeping.
    @Test func theMacGoingToSleepPausesPlayback() async throws {
        let player = Player(defaults: Settings())
        var interruptions: PlaybackInterruptions? = PlaybackInterruptions(player: player)
        defer { player.stop() }
        try await open(player)
        try #require(player.isPlaying)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        for _ in 0..<100 where player.isPlaying {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!player.isPlaying)

        // Once the observer is gone, sleep no longer touches the player.
        withExtendedLifetime(interruptions) {}
        interruptions = nil
        player.toggle()
        try #require(player.isPlaying)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.isPlaying)
    }
}
