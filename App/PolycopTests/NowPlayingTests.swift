// SPDX-License-Identifier: GPL-3.0-or-later

import MediaPlayer
import Testing

@testable import Polycop

/// A player that reads none of the user's settings: a suite of its own, never
/// written, so no file is left behind.
@MainActor
private func playerOfItsOwn() throws -> Player {
    Player(defaults: try #require(UserDefaults(suiteName: "PolycopTests-\(UUID().uuidString)")))
}

/// The system controls follow an open recording and let go of it when it stops.
@MainActor
@Test func systemControlsFollowAnOpenRecording() throws {
    let commands = MPRemoteCommandCenter.shared()
    let info = MPNowPlayingInfoCenter.default()
    let nowPlaying = NowPlaying()

    nowPlaying.activate(for: try playerOfItsOwn())
    #expect(commands.togglePlayPauseCommand.isEnabled)
    #expect(commands.nextTrackCommand.isEnabled)
    #expect(commands.changePlaybackPositionCommand.isEnabled)
    #expect(
        commands.changePlaybackRateCommand.supportedPlaybackRates.map(\.floatValue) == Player.speeds
    )

    nowPlaying.publish(title: "Synthetic", duration: 60, position: 5, speed: 1.5, isPlaying: true)
    #expect(info.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Synthetic")
    #expect(info.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
    #expect(info.playbackState == .playing)

    nowPlaying.deactivate()
    #expect(!commands.togglePlayPauseCommand.isEnabled)
    #expect(info.nowPlayingInfo == nil)
    #expect(info.playbackState == .stopped)
}

/// Every control with a fixed action, and its direction for the skips.
@MainActor
@Test func eachSystemControlMapsToItsAction() {
    let center = MPRemoteCommandCenter.shared()
    let actions = Dictionary(
        uniqueKeysWithValues: NowPlaying.fixedActions(in: center).map {
            (ObjectIdentifier($0.command), $0.action)
        })
    let step = NowPlaying.skipInterval
    let expected: [(MPRemoteCommand, RemoteAction)] = [
        (center.togglePlayPauseCommand, .togglePlayPause),
        (center.playCommand, .play),
        (center.pauseCommand, .pause),
        (center.stopCommand, .stop),
        (center.skipForwardCommand, .skip(step)),
        (center.skipBackwardCommand, .skip(-step)),
        (center.nextTrackCommand, .skip(step)),
        (center.previousTrackCommand, .skip(-step)),
    ]
    #expect(actions.count == expected.count)
    for (command, action) in expected {
        #expect(actions[ObjectIdentifier(command)] == action)
    }
}

@Test func aHeldKeySeeksOnceWhenItGoesDown() {
    #expect(NowPlaying.seekAction(for: .beginSeeking, offset: 5) == .skip(5))
    #expect(NowPlaying.seekAction(for: .endSeeking, offset: 5) == .ignore)
}

@Test func onlyTheOfferedSpeedsAreAccepted() {
    #expect(NowPlaying.speedAction(for: 1.5) == .speed(1.5))
    #expect(NowPlaying.speedAction(for: 0) == nil)
    #expect(NowPlaying.speedAction(for: 1.1) == nil)
}

/// The actions change the player as the controls promise, on the synthetic clip.
@MainActor
@Test func remoteActionsDriveThePlayer() async throws {
    let clip = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/clip-fr.wav")
    let player = try playerOfItsOwn()
    defer { player.stop() }
    player.play(clip, from: 0)
    for _ in 0..<100 where !(player.isOpen && player.duration > 0) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(player.isOpen && player.duration > 2)

    RemoteAction.pause.apply(to: player)
    #expect(!player.isPlaying)
    RemoteAction.play.apply(to: player)
    #expect(player.isPlaying)
    RemoteAction.togglePlayPause.apply(to: player)
    #expect(!player.isPlaying)

    RemoteAction.seek(2).apply(to: player)
    #expect(player.position == 2)
    RemoteAction.skip(-1).apply(to: player)
    #expect(player.position == 1)
    RemoteAction.skip(-5).apply(to: player)
    #expect(player.position == 0)
    RemoteAction.skip(1000).apply(to: player)
    #expect(player.position == player.duration)

    RemoteAction.speed(1.5).apply(to: player)
    #expect(player.speed == 1.5)
    RemoteAction.ignore.apply(to: player)
    #expect(player.speed == 1.5)

    RemoteAction.stop.apply(to: player)
    #expect(!player.isOpen)
}
