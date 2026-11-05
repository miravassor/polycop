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

    /// Copies the library in `root` if `version` is not the one that last opened
    /// it, before anything reads it: opening a library can rewrite its records.
    /// On APFS the copy is a clone, so a library rewritten later costs at most
    /// one old library per copy. A failure never stops the launch: it is logged
    /// and tried again at the next one. Tests set `now` to tell their copies apart.
    static func take(before version: String, in root: URL, now: Date = .now) {
        let folder = root.appending(path: "Snapshots")
        let lastVersion = folder.appending(path: ".version")
        guard (try? String(contentsOf: lastVersion, encoding: .utf8)) != version else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if try copied.contains(where: { try !contents(of: root.appending(path: $0)).isEmpty }) {
                try copy(root, to: folder.appending(path: name(before: version, at: now)))
            }
            try version.write(to: lastVersion, atomically: true, encoding: .utf8)
            // Names start with the date, so they sort oldest first.
            let snapshots = try contents(of: folder).sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
            for old in snapshots.dropLast(kept) { try manager.removeItem(at: old) }
        } catch {
            Log.persistence.error("the library could not be copied: \(error, privacy: .private)")
        }
    }

    /// Takes a file about to be deleted from the library out of every copy, so
    /// that what the user deleted does not stay behind.
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
            at: partial, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in copied {
            let source = root.appending(path: name)
            guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try manager.copyItem(at: source, to: partial.appending(path: name))
        }
        try manager.moveItem(at: partial, to: snapshot)
    }

    private static func name(before version: String, at date: Date) -> String {
        // No colon, which the Finder shows as a slash.
        let time = date.formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: false)
                .timeSeparator(.omitted))
        return "\(time) before \(version)"
    }

    /// No folder means nothing in it yet. Hidden files are not the library's nor
    /// a copy: the last version, a partial copy, the Finder's.
    private static func contents(of folder: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }
}
