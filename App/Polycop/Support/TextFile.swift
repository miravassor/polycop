// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Decodes text as UTF-8 first, then as UTF-16 when a byte order mark marks it
/// (used by some Windows editors), then as Windows Latin for older French text.
nonisolated enum TextFile {
    static func decode(_ data: Data) -> String? {
        guard let text = decoded(data) else { return nil }
        // A UTF-8 byte order mark, as Excel and older Notepad write it, is
        // kept by some versions of Foundation. Left in, it sticks invisibly to
        // the first glossary term or the first cue.
        guard text.unicodeScalars.first == "\u{feff}" else { return text }
        return String(text.unicodeScalars.dropFirst())
    }

    private static func decoded(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
            let text = String(data: data, encoding: .utf16)
        {
            return text
        }
        return String(data: data, encoding: .windowsCP1252)
    }
}
