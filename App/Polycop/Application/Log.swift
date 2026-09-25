// SPDX-License-Identifier: GPL-3.0-or-later

import os

/// Where the detail behind a failure goes: the window says what a user can
/// act on, the rest is readable in Console afterwards. Nothing leaves the Mac.
///
/// No lecture text is ever logged, and paths are interpolated as private, so
/// the system redacts them.
nonisolated enum Log {
    private static let subsystem = "io.github.miravassor.Polycop"

    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let models = Logger(subsystem: subsystem, category: "models")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let updates = Logger(subsystem: subsystem, category: "updates")
}
