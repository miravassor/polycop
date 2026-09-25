// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

nonisolated struct TranscriptFolder: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
}
