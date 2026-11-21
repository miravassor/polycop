// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: Failures shown in the window

extension AppModel {
    struct EntryFailure: Equatable {
        let id: Entry.ID
        let message: String
    }

    /// Shows an error a view ran into, such as a file panel that failed.
    func report(_ error: any Error) {
        failure = error.localizedDescription
    }

    /// Shows an error a view ran into for one transcript, such as a file panel
    /// that failed, scoped to that transcript.
    func report(_ error: any Error, for id: Entry.ID) {
        guard !isShuttingDown, entry(id) != nil else { return }
        entryFailure = EntryFailure(id: id, message: error.localizedDescription)
    }

    func failure(for id: Entry.ID) -> String? {
        entryFailure?.id == id ? entryFailure?.message : nil
    }
}
