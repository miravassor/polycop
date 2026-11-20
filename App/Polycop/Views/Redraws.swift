// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
        /// What a window counted, in a value its table can hold.
        private final class Runs {
            var counts: [Piece: Int] = [:]
        }

        // On the main actor, as every body: one thread reads and writes them.
        // Their keys are weak: what a window counted goes with its model, and a
        // model made where one gone was starts from nothing.
        private static let runs = NSMapTable<AppModel, Runs>.weakToStrongObjects()
        private static let pointers = NSMapTable<AppModel, ParagraphPointer>.weakToWeakObjects()

        /// The runs of each piece of the window of `model` so far.
        static func counts(in model: AppModel) -> [Piece: Int] {
            runs.object(forKey: model)?.counts ?? [:]
        }

        /// The pointer of the page the window of `model` shows.
        static func pointer(of model: AppModel) -> ParagraphPointer? {
            pointers.object(forKey: model)
        }
    #endif

    /// Counts a run of the body of `piece` in the window of `model`.
    static func count(_ piece: Piece, in model: AppModel) {
        #if DEBUG
            guard TestHost.isRunning else { return }
            let window = runs.object(forKey: model) ?? Runs()
            window.counts[piece, default: 0] += 1
            runs.setObject(window, forKey: model)
        #endif
    }

    /// Keeps the pointer of the page the window of `model` shows, which a test
    /// moves as the reader's pointer does: the page keeps it to itself.
    static func keep(_ pointer: ParagraphPointer, of model: AppModel) {
        #if DEBUG
            guard TestHost.isRunning else { return }
            pointers.setObject(pointer, forKey: model)
        #endif
    }
}
