// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreAudio
import os

/// Pauses playback when the Mac is about to sleep and when the audio output
/// it plays through goes away, as Music and Podcasts do: a lecture heard in
/// headphones must not move to the speakers when they disconnect. Plugging in
/// headphones, or choosing another output, keeps playing there. Playback the
/// user then resumes behaves as any other resume.
final class PlaybackInterruptions {
    private weak var player: Player?
    private let center: NotificationCenter
    private var sleepObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// The output playback goes to, to tell a device that left from one that
    /// arrived when the default changes.
    private var output = PlaybackInterruptions.defaultOutput()

    /// The default output device is a property of the system object.
    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// `center` is the workspace's, where the system posts sleep; tests give
    /// one of their own, so a test never pauses another test's player.
    /// `watchesOutput` lets tests leave the real audio devices alone.
    init(
        player: Player, center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        watchesOutput: Bool = true
    ) {
        self.player = player
        self.center = center
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt() }
        }
        guard watchesOutput else { return }
        // Delivered on the main queue, so the block can reach the main actor.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, listener)
        if status == noErr {
            deviceListener = listener
        } else {
            Log.playback.error("could not watch the output device: \(status)")
        }
    }

    /// Pauses, and keeps paused what typing was about to resume.
    func interrupt() {
        player?.pause()
    }

    private func outputChanged() {
        let previous = output
        output = Self.defaultOutput()
        if Self.wentAway(previous, devices: Self.devices()) { interrupt() }
    }

    /// Whether the output playback went to is no longer there. A device that
    /// is still connected was left by choice, or for one just plugged in.
    static func wentAway(_ previous: AudioDeviceID?, devices: [AudioDeviceID]) -> Bool {
        guard let previous else { return false }
        return !devices.contains(previous)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }
        var devices = [AudioDeviceID](
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return Array(devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    // The listener is removed with the queue and block it was added with.
    isolated deinit {
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let deviceListener {
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main,
                deviceListener)
            if status != noErr {
                Log.playback.error("could not stop watching the output device: \(status)")
            }
        }
    }
}
