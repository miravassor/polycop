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

@MainActor
@Test func resumingStepsBackSoTheSentenceIsHeardAgain() async throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    let player = Player(defaults: defaults)
    defer {
        player.stop()
        defaults.removePersistentDomain(forName: suite)
    }
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
    defaults.set(0.0, forKey: Player.resumeRewindKey)
    player.toggle()
    #expect(player.position == 3)
}

@MainActor
@Test func typingPausesPlaybackUnlessTheSettingIsOff() async throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    let player = Player(defaults: defaults)
    defer {
        player.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    try await open(player)
    #expect(player.isPlaying)

    player.pauseForTyping()
    #expect(!player.isPlaying)

    player.toggle()
    defaults.set(false, forKey: Player.pausesWhileTypingKey)
    player.pauseForTyping()
    #expect(player.isPlaying)
}
