// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What went wrong with the library itself, above whatever page is shown:
/// changes that could not be stored, and files that could not be read.
struct LibraryWarnings: View {
    let model: AppModel

    var body: some View {
        if let failure = model.storageFailure {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Changes could not be stored", systemImage: "exclamationmark.triangle"
                )
                .font(.callout.weight(.semibold))
                Text(failure)
                    .font(.callout)
                    .textSelection(.enabled)
                Button("Retry Saving") { Task { await model.retrySavingHistory() } }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            Divider()
        }
        if let warning = model.libraryWarning {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Part of your library could not be read",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout.weight(.semibold))
                Text(warning)
                    .font(.callout)
                    .textSelection(.enabled)
                if model.foldersAreDamaged {
                    Text(
                        "Folders cannot be created, renamed or deleted, and transcripts cannot be moved between them, until the file that lists them is repaired or removed, so that nothing writes over it or loses which folder a transcript is in."
                    )
                    .font(.callout)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            Divider()
        }
    }
}
