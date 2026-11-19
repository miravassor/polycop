// SPDX-License-Identifier: GPL-3.0-or-later

/// How many times each view that declares the window's structure ran its
/// body, for `RedrawTests`, which state what each change on the page may
/// redraw. An API added for those tests: it counts only in the test host, and
/// a release build has neither the counts nor the work.
///
/// Counted by the model the window draws, so that tests hosting pages at the
/// same time each read their own window's counts.
enum Redraws {
    nonisolated enum Piece: CaseIterable {
        /// `ContentView`: the split view, the library's list, the window's minimum.
        case window
        /// `EntryView`: the page's title, toolbar, inspector and focused values.
        case page
        /// `EntryTools`: the page's tools in the toolbar.
        case tools
        /// `EntryInspector`: what the inspector's column shows.
        case inspector
    }

    #if DEBUG
        // On the main actor, as every body: one thread reads and writes them.
        private static var counts: [ObjectIdentifier: [Piece: Int]] = [:]
        private static var pointers: [ObjectIdentifier: ParagraphPointer] = [:]

        /// The runs of each piece of the window of `model` so far. Compare two
        /// readings: a model made where one gone was takes up its counts.
        static func counts(in model: AppModel) -> [Piece: Int] {
            counts[ObjectIdentifier(model)] ?? [:]
        }

        /// The pointer of the page the window of `model` shows.
        static func pointer(of model: AppModel) -> ParagraphPointer? {
            pointers[ObjectIdentifier(model)]
        }
    #endif

    /// Counts a run of the body of `piece` in the window of `model`.
    static func count(_ piece: Piece, in model: AppModel) {
        #if DEBUG
            guard TestHost.isRunning else { return }
            counts[ObjectIdentifier(model), default: [:]][piece, default: 0] += 1
        #endif
    }

    /// Keeps the pointer of the page the window of `model` shows, which a test
    /// moves as the reader's pointer does: the page keeps it to itself.
    static func keep(_ pointer: ParagraphPointer, of model: AppModel) {
        #if DEBUG
            guard TestHost.isRunning else { return }
            pointers[ObjectIdentifier(model)] = pointer
        #endif
    }
}
