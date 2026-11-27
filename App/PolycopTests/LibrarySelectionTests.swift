// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Testing

@testable import Polycop

/// Two transcripts selected in the library, the library hidden, then a filter
/// chosen in the View menu that lists only one of them: the window shows that
/// one, rather than a selection of two the library no longer lists.
@MainActor
@Test func aFilterChosenWhileTheLibraryIsHiddenKeepsOnlyWhatItLists() async throws {
    var entry = Entry(
        recording: HostedPage.clipFR, modelFile: ModelCatalog.recommended.id, glossary: nil,
        skipsSilence: false, subtitles: false)
    entry.publish([Segment(start: 0, end: 3, text: "Le cours porte sur Freud.")], partial: false)
    entry.state = .finished
    try await withHostedPage(entry) { page in
        let (model, id) = (page.model, page.id)
        try #require(model.duplicate(id) != nil)
        model.rename(id, to: "Cours de mardi")
        model.toggleFlair(.done, on: [id])
        try await page.open()

        // Command-A in the library's list.
        let list = try #require(
            page.window.contentView.flatMap(selectableList(in:)), "the library has no list")
        list.selectAll(nil)
        for _ in 0..<20 where page.window.title != "2 Transcripts Selected" { await turns(1) }
        try #require(page.window.title == "2 Transcripts Selected")

        model.layout.showsLibrary = false
        for _ in 0..<20 where !list.isHiddenOrHasHiddenAncestor { await turns(1) }
        try #require(list.isHiddenOrHasHiddenAncestor, "the library still shows")
        model.layout.filter = .flair(.done)
        for _ in 0..<20 where page.window.title != "Cours de mardi" { await turns(1) }
        #expect(page.window.title == "Cours de mardi")
        #expect(model.pane == .entry(id))
    }
}

/// The list the library draws its rows in, the one where several rows can be
/// chosen.
@MainActor
private func selectableList(in view: NSView) -> NSTableView? {
    if let list = view as? NSTableView, list.allowsMultipleSelection { return list }
    return view.subviews.lazy.compactMap(selectableList(in:)).first
}
