// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A transcript's name is its recording's file name until the user renames
/// it, so only the recording's own extension counts as one: in a name such
/// as "Séance 3.2", what follows the dot is part of the name.
nonisolated enum RecordingName {
    /// The name without the recording's extension, and that extension with
    /// its dot, or empty when the name does not end with it.
    static func split(_ name: String, of recording: URL) -> (stem: String, suffix: String) {
        let suffix = "." + recording.pathExtension
        guard !recording.pathExtension.isEmpty,
            name.range(of: suffix, options: [.anchored, .backwards, .caseInsensitive]) != nil
        else { return (name, "") }
        return (String(name.dropLast(suffix.count)), String(name.suffix(suffix.count)))
    }
}
