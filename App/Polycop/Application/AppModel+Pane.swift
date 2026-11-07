// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension AppModel {
    /// What the window shows: the pane for new transcriptions, or one entry.
    enum Pane: Hashable {
        case new
        case entry(Entry.ID)
        /// A record this version cannot read, which has a page saying so.
        case unavailable(UnavailableRecord.ID)
        /// Every file nothing identifies, together.
        case unidentifiedFiles
    }

    static let openTranscriptKey = "openTranscript"

    /// Kept for the next launch. Any other pane opens on New Transcription: a
    /// record that could not be read is listed in the library for what to do.
    func rememberOpenTranscript() {
        if case .entry(let id) = pane {
            defaults.set(id.uuidString, forKey: Self.openTranscriptKey)
        } else {
            defaults.removeObject(forKey: Self.openTranscriptKey)
        }
    }

    /// Opens the transcript left open last time, while the library still has
    /// it, with its row in view. At launch, so what leaving a pane clears is
    /// still empty.
    func reopenTranscript() {
        guard
            let id = defaults.string(forKey: Self.openTranscriptKey)
                .flatMap(UUID.init(uuidString:)), let entry = entry(id)
        else { return }
        pane = .entry(id)
        if let folder = entry.folderID { layout.openFolders.insert(folder) }
    }
}
