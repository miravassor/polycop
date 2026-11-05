// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Copies of the library from before the last versions opened it, the only undo
/// for a release that damages records: a write replaces the one copy of a
/// record, and nobody goes back to an older version. Restoring is by hand, as
/// the README says.
nonisolated enum LibrarySnapshots {
    /// Two, since a version that fixes a damaging one takes its copy of the
    /// damaged library, which must not replace the last good copy.
    private static let kept = 2
    /// What only the user can make. Models can be downloaded again.
    private static let copied = ["History", "Glossaries"]

    /// Copies the library in `root` unless the last copy was taken before this
    /// same version, before anything reads it: opening a library can rewrite its
    /// records. The folder is the only record of it, so no stored version can
    /// disagree with the copies. On APFS the copy is a clone, so a library
    /// rewritten later costs at most one old library per copy. A failure never
    /// stops the launch: it is logged and tried again at the next one. Tests set
    /// `now` to tell their copies apart.
    static func take(before version: String, in root: URL, now: Date = .now) {
        let folder = root.appending(path: "Snapshots")
        // Names start with the date, so they sort oldest first.
        func snapshots() throws -> [URL] {
            try contents(of: folder).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let ending = " before \(version)"
        do {
            guard try snapshots().last?.lastPathComponent.hasSuffix(ending) != true,
                try copied.contains(where: { try !contents(of: root.appending(path: $0)).isEmpty })
            else { return }
            try copy(root, to: folder.appending(path: timestamp(now) + ending))
            for old in try snapshots().dropLast(kept) {
                try FileManager.default.removeItem(at: old)
            }
        } catch {
            Log.persistence.error("the library could not be copied: \(error, privacy: .private)")
        }
    }

    /// Takes a file out of every copy, before it leaves the library: if this
    /// fails, the user is told and the file is still there to delete again, rather
    /// than gone from the library and kept in a copy.
    static func remove(_ file: URL) throws {
        let library = file.deletingLastPathComponent()
        let folder = library.deletingLastPathComponent().appending(path: "Snapshots")
        for snapshot in try contents(of: folder) {
            let copy = snapshot.appending(path: library.lastPathComponent)
                .appending(path: file.lastPathComponent)
            do {
                try FileManager.default.removeItem(at: copy)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Made after this copy was taken.
            }
        }
    }

    /// Under a temporary name until it is whole, so that a copy cut short is
    /// never taken for one to restore.
    private static func copy(_ root: URL, to snapshot: URL) throws {
        let manager = FileManager.default
        let partial = snapshot.deletingLastPathComponent().appending(path: ".partial")
        try? manager.removeItem(at: partial)
        defer { try? manager.removeItem(at: partial) }
        try manager.createDirectory(
            at: partial, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in copied {
            let source = root.appending(path: name)
            guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try manager.copyItem(at: source, to: partial.appending(path: name))
        }
        try manager.moveItem(at: partial, to: snapshot)
    }

    /// No colon, which the Finder shows as a slash.
    private static func timestamp(_ date: Date) -> String {
        date.formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: false)
                .timeSeparator(.omitted))
    }

    /// No folder means nothing in it yet. Hidden files are neither the library's
    /// nor a copy: a partial copy, the Finder's.
    private static func contents(of folder: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }
}
