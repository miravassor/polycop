// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension Entry {
    /// The layout the export uses.
    var exportLayout: Transcript.TextLayout {
        exportsWord == true ? .word : (textLayout ?? .timestamped)
    }

    var exportFormat: Transcript.Format {
        switch exportLayout {
        case .timestamped, .plain: .plainText
        case .markdown: .markdown
        case .word: .word
        }
    }

    /// Whether the export times its paragraphs; plain text by its layout.
    var exportsTimes: Bool {
        switch exportLayout {
        case .timestamped: true
        case .plain: false
        case .markdown, .word: includesTimes ?? true
        }
    }
}
