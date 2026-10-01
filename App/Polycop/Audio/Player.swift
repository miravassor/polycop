// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Observation
import os

nonisolated enum PlaybackError: LocalizedError {
    case missing(URL)
    case unplayable(URL)

    var errorDescription: String? {
        switch self {
        case .missing(let recording):
            String(
                localized: "The recording is no longer where it was: \(recording.lastPathComponent)"
            )
        case .unplayable(let recording):
            String(localized: "The recording could not be played: \(recording.lastPathComponent)")
        }
    }
}

/// Plays a recording at transcript timestamps. Unsupported formats use a temporary
/// 16-bit PCM copy, deleted when playback stops (about 108 MB per hour).
@Observable
final class Player {
    private(set) var isPreparing = false
    private(set) var isPlaying = false
    /// Seconds into the recording.
    private(set) var position: TimeInterval = 0
    /// Length of the open recording, zero until it is known.
    private(set) var duration: TimeInterval = 0
    /// How fast it plays. AVFoundation's spectral algorithm keeps the pitch
    /// correct well beyond the quarter to four times range the app offers.
    var speed: Float = 1 {
        didSet {
            guard isPlaying else { return }
            player?.rate = speed
            publishNowPlaying()
        }
    }
    private(set) var failure: String?

    /// The speeds offered by the player bar and to the system controls.
    nonisolated static let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    /// Decoded copies, emptied at launch in case a run did not quit normally.
    nonisolated static let copies = URL.temporaryDirectory.appending(path: "Polycop Replay")

    private var player: AVPlayer?
    private var recording: URL?
    private var copy: URL?
    private var observer: Any?
    private var preparation: Task<Void, Never>?
    @ObservationIgnored private let nowPlaying = NowPlaying()
    @ObservationIgnored private let defaults: UserDefaults
    /// Whether playback was paused while playing, as opposed to moved while
    /// paused: only the first resumes a little earlier.
    @ObservationIgnored private var resumesEarlier = false
    /// A position asked for and not yet reached, since the audio first fades.
    @ObservationIgnored private var pendingSeek: TimeInterval?
    /// The fade bringing the audio to what was asked, if one runs.
    @ObservationIgnored private var transition: Task<Void, Never>?
    /// Resumes playback that typing paused, once typing stops. Any command of
    /// the user's own cancels it.
    @ObservationIgnored private var resumeAfterTyping: Task<Void, Never>?
    /// A waveform cut in the middle is heard as a click, so the audio fades
    /// around every change: briefly for a jump or a stop, longer for a pause
    /// or a start, as a sentence would.
    private static let cut: Duration = .milliseconds(30)
    private static let fade: Duration = .milliseconds(80)

    /// Settings keys, shared with the Settings window.
    static let resumeRewindKey = "resumeRewind"
    static let pausesWhileTypingKey = "pausesWhileTyping"
    static let resumeAfterTypingKey = "resumeAfterTyping"
    static let cursorFollowsPlaybackKey = "cursorFollowsPlayback"
    /// How far back playback resumes after a pause, so the sentence is heard again.
    static let defaultResumeRewind: TimeInterval = 1.5
    /// How long typing must stop before playback it paused resumes, in seconds.
    static let defaultResumeAfterTyping: TimeInterval = 2

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var resumeRewind: TimeInterval {
        defaults.object(forKey: Self.resumeRewindKey) as? Double ?? Self.defaultResumeRewind
    }

    /// A file is open, playing or not.
    var isOpen: Bool { player != nil }

    func play(_ recording: URL, from time: TimeInterval) {
        guard time.isFinite else { return }
        cancelResumeAfterTyping()
        failure = nil
        if recording == self.recording, let player {
            seek(player, to: time)
            return
        }
        stop()
        self.recording = recording
        isPreparing = true
        preparation = Task {
            do {
                let file = try await Player.playableFile(for: recording)
                // A stop or another recording came first, so this one is not wanted.
                guard !Task.isCancelled else {
                    if file != recording { try? FileManager.default.removeItem(at: file) }
                    return
                }
                isPreparing = false
                if file != recording { copy = file }
                open(file, at: time)
            } catch {
                guard !Task.isCancelled else { return }
                isPreparing = false
                self.recording = nil
                Log.playback.error("could not open a recording: \(error, privacy: .private)")
                failure = error.localizedDescription
            }
        }
    }

    func toggle() {
        guard let player else { return }
        cancelResumeAfterTyping()
        if isPlaying {
            resumesEarlier = true
            isPlaying = false
            apply(player, fadeOut: Self.fade)
        } else {
            if duration > 0, position >= duration - 0.05 {
                ask(for: 0)
            } else if resumesEarlier {
                ask(for: position - resumeRewind)
            }
            resumesEarlier = false
            isPlaying = true
            apply(player, fadeOut: Self.cut)
        }
        publishNowPlaying()
    }

    /// Records a position at once; `apply` takes the audio there.
    private func ask(for time: TimeInterval) {
        // Until the length is known, the longest recording the app accepts
        // bounds the position.
        let time = min(max(0, time), duration > 0 ? duration : AudioDecoder.longestRecording)
        position = time
        pendingSeek = time
        resumesEarlier = false
    }

    /// Takes the audio to what was asked: the pending position, then playing
    /// or paused. What was asked is already shown; the audio fades out first
    /// when it sounds, and in when it starts. A later request cancels the fade
    /// but never the position, which stays pending until reached.
    private func apply(_ player: AVPlayer, fadeOut: Duration) {
        transition?.cancel()
        let sounds = player.rate != 0 && player.volume > 0
        transition = Task { [weak self] in
            if sounds {
                await Self.ramp(player, to: 0, over: fadeOut)
                guard !Task.isCancelled else { return }
            }
            guard let self, self.player === player else { return }
            if let time = pendingSeek {
                pendingSeek = nil
                player.seek(
                    to: CMTime(seconds: time, preferredTimescale: 1000), toleranceBefore: .zero,
                    toleranceAfter: .zero, completionHandler: { _ in })
            }
            if isPlaying {
                player.volume = 0
                player.rate = speed
                await Self.ramp(player, to: 1, over: sounds ? Self.cut : Self.fade)
            } else {
                player.pause()
                player.volume = 1
            }
            if !Task.isCancelled { transition = nil }
        }
    }

    /// Small steps, which the ear takes for a smooth fade.
    private static func ramp(_ player: AVPlayer, to target: Float, over duration: Duration) async {
        let start = player.volume
        let steps = max(1, Int(duration / .milliseconds(5)))
        for step in 1...steps {
            try? await Task.sleep(for: duration / steps)
            guard !Task.isCancelled else { return }
            player.volume = start + (target - start) * Float(step) / Float(steps)
        }
    }

    /// Pauses when the user starts typing a correction, unless the setting is
    /// off, and resumes once typing has stopped for the delay set, stepping
    /// back as any resume does. Playback the user paused stays paused.
    func pauseForTyping() {
        if isPlaying {
            guard defaults.object(forKey: Self.pausesWhileTypingKey) as? Bool ?? true else {
                return
            }
            toggle()
        } else if resumeAfterTyping == nil {
            return
        }
        resumeAfterTyping?.cancel()
        let delay =
            defaults.object(forKey: Self.resumeAfterTypingKey) as? Double
            ?? Self.defaultResumeAfterTyping
        guard delay > 0 else {
            resumeAfterTyping = nil
            return
        }
        // Each key typed starts the wait again.
        resumeAfterTyping = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !isPlaying else { return }
            resumeAfterTyping = nil
            toggle()
        }
    }

    /// Pauses, and keeps paused what typing was about to resume.
    func pause() {
        cancelResumeAfterTyping()
        if isPlaying { toggle() }
    }

    private func cancelResumeAfterTyping() {
        resumeAfterTyping?.cancel()
        resumeAfterTyping = nil
    }

    /// Moves `offset` seconds from the current position, as the skip buttons do.
    func skip(by offset: TimeInterval) {
        seek(to: position + offset)
    }

    /// Where the user asked to be, exactly, unlike a jump from a paragraph.
    func seek(to time: TimeInterval) {
        guard time.isFinite, let player else { return }
        cancelResumeAfterTyping()
        ask(for: time)
        apply(player, fadeOut: Self.cut)
        publishNowPlaying()
    }

    /// Releases playback, deletes the temporary copy and clears recording-specific errors.
    func stop() {
        failure = nil
        preparation?.cancel()
        preparation = nil
        transition?.cancel()
        transition = nil
        pendingSeek = nil
        cancelResumeAfterTyping()
        nowPlaying.deactivate()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        if let player, player.rate != 0, player.volume > 0 {
            // Let go at once, but faded out rather than cut.
            Task { @MainActor in
                await Self.ramp(player, to: 0, over: Self.cut)
                player.pause()
            }
        } else {
            player?.pause()
        }
        player = nil
        if let copy { try? FileManager.default.removeItem(at: copy) }
        copy = nil
        recording = nil
        isPreparing = false
        isPlaying = false
        position = 0
        duration = 0
    }

    /// The recording itself when AVFoundation can play it, otherwise a decoded
    /// copy in `folder`. Asking AVFoundation rather than listing formats keeps
    /// this working on an older macOS, which may play fewer of them.
    @concurrent
    nonisolated static func playableFile(for recording: URL, in folder: URL = copies)
        async throws -> URL
    {
        try Task.checkCancellation()
        guard recording.isFileURL else { throw PlaybackError.unplayable(recording) }
        guard FileManager.default.fileExists(atPath: recording.path(percentEncoded: false)) else {
            throw PlaybackError.missing(recording)
        }
        let playable = try? await AVURLAsset(url: recording).load(.isPlayable)
        try Task.checkCancellation()
        if playable == true {
            return recording
        }
        let samples = try await AudioDecoder.samples(of: recording)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appending(path: UUID().uuidString + ".caf")
        do {
            try write(samples, to: copy)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
        return copy
    }

    nonisolated static func sweep(in folder: URL = copies) {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open(_ file: URL, at time: TimeInterval) {
        let asset = AVURLAsset(
            url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        // Speech at half or double speed is unlistenable when the pitch follows.
        item.audioTimePitchAlgorithm = .spectral
        let player = AVPlayer(playerItem: item)
        Task { [weak self] in
            guard let length = try? await asset.load(.duration),
                let self, self.player === player, length.seconds.isFinite
            else { return }
            self.duration = max(0, length.seconds)
            self.publishNowPlaying()
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.update(time) }
        }
        self.player = player
        nowPlaying.activate(for: self)
        seek(player, to: time)
    }

    /// Called four times a second, and whenever playback starts or stops.
    private func update(_ time: CMTime) {
        guard let player, time.seconds.isFinite else { return }
        // A position asked for stands until the audio has gone there.
        if pendingSeek == nil { position = time.seconds }
        let wasPlaying = isPlaying
        // While a fade runs, what was asked stands. Otherwise the player can
        // only end playback, as at the end of the recording: it never starts
        // on its own, and audio still running after a pause is stopped.
        if transition == nil {
            if isPlaying, player.rate == 0 {
                isPlaying = false
            } else if !isPlaying, player.rate != 0 {
                player.pause()
            }
        }
        if isPlaying != wasPlaying { publishNowPlaying() }
        if player.currentItem?.status == .failed, let recording {
            failure = PlaybackError.unplayable(recording).localizedDescription
        }
    }

    /// Opens at the requested point; paragraph actions supply their own lead-in.
    private func seek(_ player: AVPlayer, to time: TimeInterval) {
        ask(for: time)
        isPlaying = true
        apply(player, fadeOut: Self.cut)
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        guard player != nil, let recording else { return }
        nowPlaying.publish(
            title: recording.deletingPathExtension().lastPathComponent, duration: duration,
            position: position, speed: speed, isPlaying: isPlaying)
    }

    /// 16-bit audio is enough for playback, and half the size of the samples.
    private nonisolated static func write(_ samples: [Float], to file: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(AudioDecoder.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let output = try AVAudioFile(
            forWriting: file, settings: settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let minute = AudioDecoder.sampleRate * 60
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let count = min(minute, samples.count - offset)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(count))
            else { throw CocoaError(.fileWriteUnknown) }
            // A float buffer of a float format always has channel data and the
            // samples are never empty here, but a copy through a raw pointer
            // should fail like anything else rather than end the process.
            try samples.withUnsafeBufferPointer { source in
                guard let channel = buffer.floatChannelData?[0], let first = source.baseAddress
                else { throw CocoaError(.fileWriteUnknown) }
                channel.update(from: first + offset, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try output.write(from: buffer)
            offset += count
        }
    }
}
