// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

private func temporaryFolder() -> URL {
    URL.temporaryDirectory.appending(path: UUID().uuidString)
}

/// Excel's "CSV UTF-8" starts with a byte order mark. Kept, it would make the
/// first term a different word that no recording ever matches.
@Test func aByteOrderMarkStaysOutOfTheFirstTerm() throws {
    let folder = temporaryFolder()
    let elsewhere = temporaryFolder()
    defer {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let file = elsewhere.appending(path: "Philosophie.txt")
    try (Data([0xef, 0xbb, 0xbf]) + Data("Héloïse\nAbélard".utf8)).write(to: file)

    let glossary = try GlossaryStore.importFile(file, in: folder)

    #expect(Glossary.terms(in: glossary.text) == ["Héloïse", "Abélard"])
    #expect(TextFile.decode(Data([0xef, 0xbb, 0xbf]) + Data("Pascal".utf8)) == "Pascal")
    #expect(TextFile.decode(Data([0xff, 0xfe, 0x41, 0x00])) == "A")
}
