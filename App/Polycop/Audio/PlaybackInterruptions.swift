// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreAudio
import os

/// Pauses playback when the Mac is about to sleep and when the default audio
/// output changes, as Music and Podcasts do: a lecture heard in headphones
/// must not move to the speakers when they disconnect. Playback the user then
/// resumes behaves as any other resume.
final class PlaybackInterruptions {
    private weak var player: Player?
    private var sleepObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// The default output device is a property of the system object.
    private static var outputDevice = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(player: Player) {
        self.player = player
        // Posted on the workspace's own center, not the default one.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt() }
        }
        // Delivered on the main queue, so the block can reach the main actor.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.interrupt() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.outputDevice, .main, listener)
        if status == noErr {
            deviceListener = listener
        } else {
            Log.playback.error("could not watch the output device: \(status)")
        }
    }

    /// What both observers call. A pause also keeps paused what typing was
    /// about to resume.
    func interrupt() {
        player?.pause()
    }

    // The listener is removed with the queue and block it was added with.
    isolated deinit {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let deviceListener {
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.outputDevice, .main, deviceListener)
            if status != noErr {
                Log.playback.error("could not stop watching the output device: \(status)")
            }
        }
    }
}
