// SPDX-License-Identifier: GPL-3.0-or-later

import CoreTransferable
import UniformTypeIdentifiers

/// Library rows dragged onto a folder. Carried as a type of the app's own,
/// declared in its Info.plist, so that no text view, here or in another
/// app, takes them as text.
nonisolated struct DraggedTranscripts: Codable, Transferable {
    let ids: [Entry.ID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .transcripts)
    }
}

extension UTType {
    nonisolated static let transcripts = UTType(
        exportedAs: "io.github.miravassor.Polycop.transcripts")
}
