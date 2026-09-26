// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

private let clip = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/clip-fr.wav")

/// Opens the synthetic clip and waits until its duration is known.
@MainActor
private func open(_ player: Player) async throws {
    player.play(clip, from: 0)
    for _ in 0..<100 where !(player.isOpen && player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(player.isOpen && player.duration > 3)
}

/// The position once it holds still, as it does when a fade has ended. A busy
/// machine can stretch a fade well past its length, so this waits rather than
/// assuming a duration; the time observer reports four times a second.
@MainActor
private func settledPosition(of player: Player) async throws -> TimeInterval {
    var position = player.position
    for _ in 0..<20 {
        try await Task.sleep(for: .milliseconds(300))
        if player.position == position { break }
        position = player.position
    }
    return position
}

@MainActor
@Test func resumingStepsBackSoTheSentenceIsHeardAgain() async throws {
    // Settings are registered, which keeps them in memory: a set value would
    // leave a preferences file behind.
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let player = Player(defaults: defaults)
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
    defaults.register(defaults: [Player.resumeRewindKey: 0.0])
    player.toggle()
    #expect(player.position == 3)
}

@MainActor
@Test func typingPausesPlaybackUnlessTheSettingIsOff() async throws {
    // Settings are registered, which keeps them in memory: a set value would
    // leave a preferences file behind.
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let player = Player(defaults: defaults)
    defer { player.stop() }
    try await open(player)
    #expect(player.isPlaying)

    player.pauseForTyping()
    #expect(!player.isPlaying)

    player.toggle()
    defaults.register(defaults: [Player.pausesWhileTypingKey: false])
    player.pauseForTyping()
    #expect(player.isPlaying)
}

/// Every change fades the audio rather than cutting it. What was asked shows at
/// once, the audio follows, and a position asked for is never lost to a later
/// request made during the fade.
@MainActor
@Test func changesFadeWithoutLosingWhatWasAsked() async throws {
    // Settings are registered, which keeps them in memory.
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let player = Player(defaults: defaults)
    defer { player.stop() }
    try await open(player)

    player.toggle()
    #expect(!player.isPlaying)
    let paused = try await settledPosition(of: player)
    try await Task.sleep(for: .milliseconds(400))
    #expect(player.position == paused)

    player.toggle()
    #expect(player.isPlaying)
    let resumed = player.position
    for _ in 0..<100 where player.position <= resumed {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(player.position > resumed)

    player.seek(to: 2)
    #expect(player.position == 2)
    for _ in 0..<100 where player.position <= 2 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(player.isPlaying)
    #expect(player.position > 2)

    player.seek(to: 3)
    player.toggle()
    #expect(!player.isPlaying)
    #expect(abs(try await settledPosition(of: player) - 3) < 0.05)
}
