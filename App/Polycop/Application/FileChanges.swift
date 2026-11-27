// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Counts the moments a file a record points to may have come or gone: a disk
/// mounted or unmounted, the app made active again, as after the reader moved
/// a file in the Finder, and an export the app wrote. The transcript page
/// looks for its recording and its last export again at each, and when its
/// record's files change, rather than at each draw, where looking resolves
/// the recording's bookmark.
@Observable
final class FileChanges {
    private(set) var count = 0
    /// Each observer, with the center it was added to, which removes it.
    @ObservationIgnored
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    /// `workspace` is where the system posts disks coming and going, and
    /// `application` where it posts the app made active; tests give centers of
    /// their own, so that a test never tells another test's pages.
    init(
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
        application: NotificationCenter = .default
    ) {
        observe(NSWorkspace.didMountNotification, on: workspace)
        observe(NSWorkspace.didUnmountNotification, on: workspace)
        observe(NSApplication.didBecomeActiveNotification, on: application)
    }

    /// One more moment, as the system's notices count, and as the app counts
    /// an export it writes.
    func note() {
        count += 1
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        // Delivered on the main queue, so the block can reach the main actor.
        let token = center.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.note() }
        }
        observers.append((center, token))
    }

    isolated deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }
}
