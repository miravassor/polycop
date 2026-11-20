// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How many times each view that declares the window's structure ran its
/// body, for `RedrawTests`, which state what each change on the page may
/// redraw, and how often the page drew where the pointer is, which they wait
/// on. An API added for those tests: it counts only in the test host, and a
/// release build has neither the counts nor the work.
///
/// Counted by the model the window draws, or the pointer of its page, so that
/// tests hosting pages at the same time each read their own window's counts.
enum Redraws {
    nonisolated enum Piece: CaseIterable {
        /// `ContentView`: the split view, the window's sheets and its minimum.
        case window
        /// `LibrarySidebar`: the library's column, its search, sections and rows.
        case library
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

        /// How often a page drew where its pointer is.
        private final class Greys {
            var drawn = 0
        }

        // On the main actor, as every body: one thread reads and writes them.
        // Their keys are weak: what a window counted goes with its model, and a
        // model made where one gone was starts from nothing.
        private static let runs = NSMapTable<AppModel, Runs>.weakToStrongObjects()
        private static let pointers = NSMapTable<AppModel, ParagraphPointer>.weakToWeakObjects()
        private static let greys = NSMapTable<ParagraphPointer, Greys>.weakToStrongObjects()

        /// The runs of each piece of the window of `model` so far.
        static func counts(in model: AppModel) -> [Piece: Int] {
            runs.object(forKey: model)?.counts ?? [:]
        }

        /// The pointer of the page the window of `model` shows.
        static func pointer(of model: AppModel) -> ParagraphPointer? {
            pointers.object(forKey: model)
        }

        /// How many times the rows of the page holding `pointer` drew where it
        /// is, or that it is elsewhere.
        static func greys(of pointer: ParagraphPointer) -> Int {
            greys.object(forKey: pointer)?.drawn ?? 0
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

    /// Counts a row drawing the grey of `pointer`, or its absence: the grey is
    /// drawn by SwiftUI alone, which a test cannot read from the window.
    static func countGrey(of pointer: ParagraphPointer) {
        #if DEBUG
            guard TestHost.isRunning else { return }
            let page = greys.object(forKey: pointer) ?? Greys()
            page.drawn += 1
            greys.setObject(page, forKey: pointer)
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
