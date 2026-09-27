// SPDX-License-Identifier: GPL-3.0-or-later

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
