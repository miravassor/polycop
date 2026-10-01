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

    func failure(for id: Entry.ID) -> String? {
        entryFailure?.id == id ? entryFailure?.message : nil
    }
}
