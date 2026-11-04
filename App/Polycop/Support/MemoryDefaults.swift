// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Settings kept in memory only. The test host and the tests use it, so they
/// never read or write the user's preferences, nor leave a preferences file.
/// The typed getters, such as `bool(forKey:)`, are the system's, which read
/// through `object(forKey:)` (`MemoryDefaultsTests` checks it), and observers
/// are told of each change, as the views reading a setting through
/// `@AppStorage` need.
nonisolated final class MemoryDefaults: UserDefaults {
    // Locked: the window's views, the models and tests running at once share it.
    private let values = OSAllocatedUnfairLock<[String: Any]>(uncheckedState: [:])

    override func object(forKey key: String) -> Any? {
        values.withLockUnchecked { $0[key] }
    }

    override func set(_ value: Any?, forKey key: String) {
        // Outside the lock: an observer reads the new value back.
        willChangeValue(forKey: key)
        values.withLockUnchecked { $0[key] = value }
        didChangeValue(forKey: key)
    }

    override func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }
    override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }

    /// The user's preferences in the app, these when it hosts the tests.
    static var forThisRun: UserDefaults { TestHost.isRunning ? MemoryDefaults() : .standard }
}
