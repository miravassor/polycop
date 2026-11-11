// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

@testable import Polycop

/// A state of the app worth looking at: a name, what it sets on a made-up
/// library, and what it does in the window once shown, such as selecting text.
/// `Tools/scenes.sh` captures each one at every size, light and dark.
@MainActor
struct Scene {
    let name: String
    let arrange: @MainActor (Stage) -> Void
    var act: @MainActor (NSWindow) async throws -> Void = { _ in }

    /// A model on a library of its own, with two recordings waiting.
    @MainActor
    struct Stage {
        let model: AppModel
        let first: Entry.ID
        let second: Entry.ID

        func change(_ id: Entry.ID, _ change: (inout Entry) -> Void) {
            guard let index = model.entries.firstIndex(where: { $0.id == id }) else { return }
            change(&model.entries[index])
        }

        /// A finished transcript, long enough to scroll.
        func finish(_ id: Entry.ID) {
            change(id) {
                $0.state = .finished
                $0.duration = 5400
                $0.paragraphs = Scene.text
            }
        }
    }

    /// Made-up text, never a real recording's.
    static let sentences = [
        "Good morning everyone. Today we start with the second part, the one on memory and how we measure it.",
        "Last week we saw the classic model with three stores. I would like to come back to one point left open.",
        "The question is how long an item stays in the short-term store when nothing refreshes it, and how we know.",
        "The first experiments used lists of letters, read once, then a delay filled with counting backwards.",
    ]

    static let text = (0..<40).map {
        Transcript.Paragraph(
            start: $0 * 135_000, text: String(repeating: sentences[$0 % 4] + " ", count: 3))
    }
}
