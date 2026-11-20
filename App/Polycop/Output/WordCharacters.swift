// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Defines which characters belong to a word across alignment, placement and search.
nonisolated enum WordCharacters {
    /// Visits each run of letters and digits in `text`, lowercased, with its UTF-16 range.
    static func runs(in text: String, _ visit: (String, NSRange) -> Void) {
        let utf8 = text.utf8
        var start: (index: String.Index, offset: Int)?
        var offset = 0
        var index = utf8.startIndex
        func close(at end: String.Index) {
            guard let first = start else { return }
            visit(
                text[first.index..<end].lowercased(),
                NSRange(location: first.offset, length: offset - first.offset))
            start = nil
        }
        while index < utf8.endIndex {
            let byte = utf8[index]
            let next = utf8.index(after: index)
            let isWord: Bool
            let width: Int
            let after: String.Index
            // An ASCII byte other than CR followed by ASCII or end of string is
            // its own single-unit character; only non-ASCII or CR needs grapheme stepping.
            if byte < 0x80, byte != 0x0D, next == utf8.endIndex || utf8[next] < 0x80 {
                isWord = isASCIIWord(byte)
                width = 1
                after = next
            } else {
                let character = text[index]
                isWord = contains(character)
                width = character.utf16.count
                after = text.index(after: index)
            }
            if isWord {
                if start == nil { start = (index, offset) }
            } else {
                close(at: index)
            }
            offset += width
            index = after
        }
        close(at: utf8.endIndex)
    }

    /// Whether the composed character at UTF-16 `index` in `text` is a letter or digit.
    static func contains(characterAt index: Int, in text: NSString) -> Bool {
        guard index >= 0, index < text.length else { return false }
        let range = text.rangeOfComposedCharacterSequence(at: index)
        return text.substring(with: range).first.map(contains) ?? false
    }

    private static func contains(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isASCIIWord(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39)
    }
}
