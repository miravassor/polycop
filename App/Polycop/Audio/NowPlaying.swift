// SPDX-License-Identifier: GPL-3.0-or-later

import MediaPlayer

/// What a system control asks of the player.
nonisolated enum RemoteAction: Equatable, Sendable {
    case togglePlayPause
    case play
    case pause
    case stop
    case skip(TimeInterval)
    case seek(TimeInterval)
    case speed(Float)
    /// A held key being released: seeking happened when it went down.
    case ignore

    @MainActor
    func apply(to player: Player) {
        switch self {
        case .togglePlayPause: player.toggle()
        case .play: if !player.isPlaying { player.toggle() }
        case .pause: if player.isPlaying { player.toggle() }
        case .stop: player.stop()
        case .skip(let offset): player.skip(by: offset)
        case .seek(let time): player.seek(to: time)
        case .speed(let speed): player.speed = speed
        case .ignore: break
        }
    }
}

/// Makes Polycop the system's Now Playing app while a recording is open, so the
/// keyboard media keys, Control Center and headphone buttons control the player.
final class NowPlaying {
    /// The step of the player bar's skip buttons.
    nonisolated static let skipInterval: TimeInterval = 5

    private var targets: [(command: MPRemoteCommand, target: Any)] = []

    /// The controls whose action does not depend on their event.
    static func fixedActions(
        in center: MPRemoteCommandCenter
    ) -> [(command: MPRemoteCommand, action: RemoteAction)] {
        [
            (center.togglePlayPauseCommand, .togglePlayPause),
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
            (center.stopCommand, .stop),
            (center.skipForwardCommand, .skip(skipInterval)),
            (center.skipBackwardCommand, .skip(-skipInterval)),
            // The rewind and fast forward keys of a Mac keyboard send the track
            // commands when pressed and the seek commands when held.
            (center.nextTrackCommand, .skip(skipInterval)),
            (center.previousTrackCommand, .skip(-skipInterval)),
        ]
    }

    /// A held key seeks one step when it goes down.
    nonisolated static func seekAction(for type: MPSeekCommandEventType, offset: TimeInterval)
        -> RemoteAction
    {
        type == .beginSeeking ? .skip(offset) : .ignore
    }

    func activate(for player: Player) {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        let interval = [NSNumber(value: Self.skipInterval)]
        center.skipForwardCommand.preferredIntervals = interval
        center.skipBackwardCommand.preferredIntervals = interval
        center.changePlaybackRateCommand.supportedPlaybackRates = Player.speeds.map {
            NSNumber(value: $0)
        }
        for (command, action) in Self.fixedActions(in: center) {
            handle(command, for: player) { _ in action }
        }
        handle(center.seekForwardCommand, for: player) {
            ($0 as? MPSeekCommandEvent).map {
                Self.seekAction(for: $0.type, offset: Self.skipInterval)
            }
        }
        handle(center.seekBackwardCommand, for: player) {
            ($0 as? MPSeekCommandEvent).map {
                Self.seekAction(for: $0.type, offset: -Self.skipInterval)
            }
        }
        handle(center.changePlaybackRateCommand, for: player) {
            ($0 as? MPChangePlaybackRateCommandEvent).map { .speed($0.playbackRate) }
        }
        handle(center.changePlaybackPositionCommand, for: player) {
            ($0 as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
        }
    }

    /// MediaPlayer calls handlers on a queue of its choosing, so each one reads
    /// its action from the event there and applies it on the main actor. An
    /// event that cannot be read fails the command.
    private func handle(
        _ command: MPRemoteCommand, for player: Player,
        action read: @escaping @Sendable (MPRemoteCommandEvent) -> RemoteAction?
    ) {
        command.isEnabled = true
        let target = command.addTarget { @Sendable [weak player] event in
            guard let player else { return .noActionableNowPlayingItem }
            guard let action = read(event) else { return .commandFailed }
            Task { @MainActor in action.apply(to: player) }
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
