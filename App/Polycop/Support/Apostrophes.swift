// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The model writes straight apostrophes and Mac keyboards often type curly
/// ones, so text that is searched or compared reads both as one. One UTF-16
/// unit replaces another: a range found in the straightened text holds in the
/// original.
nonisolated enum Apostrophes {
    static func straightened(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
