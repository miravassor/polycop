// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension Entry {
    /// The layout the export uses.
    var exportLayout: Transcript.TextLayout {
        exportsWord == true ? .word : (textLayout ?? .timestamped)
    }

    var exportFormat: Transcript.Format {
        if exportsSubtitles == true, timesSentences { return .subtitles }
        return switch exportLayout {
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

    /// The export's format and whether it times its paragraphs, kept as
    /// earlier versions read them: plain text's times in its layout, Word
    /// apart from it, and the subtitles in the flag that put them beside the
    /// text. Subtitles need a model that times its sentences.
    mutating func chooseExport(_ format: Transcript.Format, times: Bool) {
        let format = format == .subtitles && !timesSentences ? .plainText : format
        exportsSubtitles = format == .subtitles ? true : nil
        subtitles = format == .subtitles
        switch format {
        case .subtitles: break
        case .plainText:
            exportsWord = nil
            textLayout = times ? .timestamped : .plain
        case .markdown:
            exportsWord = nil
            textLayout = .markdown
        case .word:
            exportsWord = true
        }
        includesTimes = times
        isSaved = false
    }
}
