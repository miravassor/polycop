// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Settings kept in memory only. The test host and the tests use it, so they
/// never read or write the user's preferences, nor leave a preferences file.
nonisolated final class MemoryDefaults: UserDefaults {
    // Read and written on the main actor only, by the app's models and tests.
    var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }

    /// The user's preferences in the app, these when it hosts the tests.
    static var forThisRun: UserDefaults { TestHost.isRunning ? MemoryDefaults() : .standard }
}
