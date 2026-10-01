// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether the app runs as the host of the test suite, which must not ask
/// anything, reach the network, touch the user's files or make a sound.
nonisolated enum TestHost {
    static let isRunning: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }()
}
