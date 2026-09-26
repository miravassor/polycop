// SPDX-License-Identifier: GPL-3.0-or-later

import MediaPlayer

/// Makes Polycop the system's Now Playing app while a recording is open, so the
/// keyboard media keys, Control Center and headphone buttons control the player.
final class NowPlaying {
    /// The step of the player bar's skip buttons.
    static let skipInterval: TimeInterval = 5

    private var targets: [(command: MPRemoteCommand, target: Any)] = []

    func activate(for player: Player) {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        handle(center.togglePlayPauseCommand, for: player) { $0.toggle() }
        handle(center.playCommand, for: player) { if !$0.isPlaying { $0.toggle() } }
        handle(center.pauseCommand, for: player) { if $0.isPlaying { $0.toggle() } }
        handle(center.stopCommand, for: player) { $0.stop() }

        let interval = [NSNumber(value: Self.skipInterval)]
        center.skipForwardCommand.preferredIntervals = interval
        center.skipBackwardCommand.preferredIntervals = interval
        handle(center.skipForwardCommand, for: player) { $0.skip(by: Self.skipInterval) }
        handle(center.skipBackwardCommand, for: player) { $0.skip(by: -Self.skipInterval) }
        // The rewind and fast forward keys of a Mac keyboard send the track
        // commands when pressed and the seek commands when held.
        handle(center.nextTrackCommand, for: player) { $0.skip(by: Self.skipInterval) }
        handle(center.previousTrackCommand, for: player) { $0.skip(by: -Self.skipInterval) }
        handle(
            center.seekForwardCommand, for: player, read: Self.beginsSeeking,
            perform: { if $1 { $0.skip(by: Self.skipInterval) } })
        handle(
            center.seekBackwardCommand, for: player, read: Self.beginsSeeking,
            perform: { if $1 { $0.skip(by: -Self.skipInterval) } })

        center.changePlaybackRateCommand.supportedPlaybackRates = Player.speeds.map {
            NSNumber(value: $0)
        }
        handle(
            center.changePlaybackRateCommand, for: player,
            read: { ($0 as? MPChangePlaybackRateCommandEvent)?.playbackRate },
            perform: { $0.speed = $1 })
        handle(
            center.changePlaybackPositionCommand, for: player,
            read: { ($0 as? MPChangePlaybackPositionCommandEvent)?.positionTime },
            perform: { $0.seek(to: $1) })
    }

    /// Whether a held key went down, rather than up. It seeks one step when it
    /// goes down.
    private static let beginsSeeking: @Sendable (MPRemoteCommandEvent) -> Bool? = {
        ($0 as? MPSeekCommandEvent).map { $0.type == .beginSeeking }
    }

    private func handle(
        _ command: MPRemoteCommand, for player: Player,
        _ action: @escaping @MainActor (Player) -> Void
    ) {
        handle(command, for: player, read: { _ in () }, perform: { player, _ in action(player) })
    }

    /// MediaPlayer calls handlers on a queue of its choosing, so each one reads
    /// what it needs from the event there and runs the action on the main actor.
    private func handle<Value: Sendable>(
        _ command: MPRemoteCommand, for player: Player,
        read: @escaping @Sendable (MPRemoteCommandEvent) -> Value?,
        perform action: @escaping @MainActor (Player, Value) -> Void
    ) {
        command.isEnabled = true
        let target = command.addTarget { @Sendable [weak player] event in
            guard let player else { return .noActionableNowPlayingItem }
            guard let value = read(event) else { return .commandFailed }
            Task { @MainActor in action(player, value) }
            return .success
        }
        targets.append((command, target))
    }

    /// What Control Center shows. The system extrapolates the position from the
    /// rate, so this is needed only when playback changes.
    func publish(
        title: String, duration: TimeInterval, position: TimeInterval, speed: Float,
        isPlaying: Bool
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    func deactivate() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}
