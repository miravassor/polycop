// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A record this version cannot read: its format is newer than this version
/// knows, or its file is damaged. It is listed where it belongs, but it is not an
/// `Entry`, so nothing that edits, moves or writes a transcript can reach it, and
/// its file stays exactly as it was: it may be the only copy, and rewriting it
/// would lose what this version does not know.
nonisolated struct UnavailableRecord: Identifiable, Hashable, Error, Sendable {
    let file: URL
    /// Which check it failed, in words that hold none of its text: a record
    /// holds a lecture, and the log is read by whoever is sent it.
    let reason: String
    var needsNewerVersion = false
    /// What can still be read of it, nothing when the file is not even JSON.
    var name: String?
    var folderID: UUID?
    var removed: Date?

    var id: URL { file }
    /// A file nothing identifies: such files are listed together, since a row
    /// for each would say the same thing many times.
    var isUnidentified: Bool { name == nil && !needsNewerVersion }

    /// The few properties that place a record in the library, each optional so
    /// that they read in a record too damaged, or too new, to decode.
    struct Summary: Decodable {
        let requires: Int?
        let title: String?
        let recording: URL?
        let folderID: UUID?
        let removed: Date?

        var name: String? { title ?? recording?.lastPathComponent }
    }
}
