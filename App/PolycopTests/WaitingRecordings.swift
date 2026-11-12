// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import Polycop

/// Writes a library in `folder`, its history in `History`, with a recording
/// waiting for each name, in the order given: copies of `clip`, each for the
/// model named beside it.
func addWaitingRecordings(
    _ recordings: [(name: String, modelFile: String)], copying clip: URL, to folder: URL
) throws -> [Entry.ID] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return try recordings.enumerated().map { index, recording in
        let copy = folder.appending(path: recording.name)
        try FileManager.default.copyItem(at: clip, to: copy)
        // Made-up dates, in the order given.
        let added = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index))
        let entry = Entry(
            recording: copy, modelFile: recording.modelFile, glossary: nil, skipsSilence: false,
            subtitles: false, added: added)
        try HistoryStore.write(entry, in: folder.appending(path: "History"))
        return entry.id
    }
}
