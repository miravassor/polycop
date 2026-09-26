// SPDX-License-Identifier: GPL-3.0-or-later

import MediaPlayer
import Testing

@testable import Polycop

/// The system controls follow an open recording and let go of it when it stops.
@MainActor
@Test func systemControlsFollowAnOpenRecording() {
    let commands = MPRemoteCommandCenter.shared()
    let info = MPNowPlayingInfoCenter.default()
    let nowPlaying = NowPlaying()

    nowPlaying.activate(for: Player())
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
