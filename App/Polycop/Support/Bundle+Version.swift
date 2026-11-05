// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated extension Bundle {
    /// The version people know the app by, such as 0.5.0.
    var shortVersion: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
