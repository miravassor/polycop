// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import Testing

@testable import Polycop

/// The app's window, open on a transcript in a library of the test's own:
/// what a test reads of it is what a reader would see. Never seen and letting
/// clicks through, so that a run never covers the screen; a transparent
/// window lays out and draws as a visible one does. Not made key, which would
/// take that from the window of a test running beside it.
@MainActor
final class HostedPage {
    let model: AppModel
    let id: Entry.ID
    let window: NSWindow
    private let folder: URL

    init(_ entry: Entry, engines: Engines? = nil) throws {
        folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let history = folder.appending(path: "History")
        try HistoryStore.write(entry, in: history)
        model = AppModel(
            history: history, glossaries: folder.appending(path: "Glossaries"),
            playbackCopies: folder.appending(path: "Copies"), engines: engines)
        id = entry.id
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFront(nil)
    }

    /// Shows the transcript, as a click on its row in the library does, and
    /// waits for its text when it has some.
    func open() async throws {
        model.pane = .entry(id)
        await turns(2)
        guard entry?.paragraphs.isEmpty == false else { return }
        for _ in 0..<100 where textViews.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!textViews.isEmpty, "the page shows no text")
    }

    /// Stops the model's work and waits for its writes, then removes the window
    /// and the library: a write left running would make the folder again.
    func close() async {
        await model.shutDown()
        window.close()
        try? FileManager.default.removeItem(at: folder)
    }

    var entry: Entry? { model.entry(id) }

    /// The paragraphs' text views on screen, top to bottom. A row out of sight
    /// is hidden, and further away taken out of the window: both are left out.
    var textViews: [WordTextView] {
        allTextViews
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    private var allTextViews: [WordTextView] {
        func all(in view: NSView) -> [WordTextView] {
            (view as? WordTextView).map { [$0] } ?? view.subviews.flatMap { all(in: $0) }
        }
        return window.contentView.map(all(in:)) ?? []
    }

    /// The text each paragraph on screen shows, top to bottom.
    var shown: [String] { textViews.map(\.string) }

    /// The text of each paragraph the record holds.
    var held: [String]? { entry?.paragraphs.map(\.text) }

    /// The text view showing the paragraph at `index`, found by its text.
    func textView(of index: Int) throws -> WordTextView {
        let text = try #require(entry?.paragraphs[index].text)
        return try #require(textViews.first { $0.string == text })
    }

    /// Types as the keyboard does, a key at a time, at the end of a paragraph.
    func type(_ text: String, inParagraph index: Int) throws {
        let view = try textView(of: index)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        for character in text {
            view.insertText(
                String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            // One pass of the run loop that does not wait, as between real
            // keys: its timers, sources and the observers of its start and end
            // run, SwiftUI's update of the page among them. Not the main
            // actor's jobs, the pause that hands typing over among them, which
            // wait for this one to end, nor the observers of a loop about to
            // sleep, which a pass that does not wait never calls.
            RunLoop.main.run(mode: .default, before: Date())
        }
    }

    /// Hands what was typed on this page to the model, as `TypingBuffer.flush()`
    /// does for every window: the buffer is shared by the tests running at once.
    func handOver() {
        for view in allTextViews {
            (view.delegate as? ParagraphEditor.Coordinator)?.commit()
        }
    }

    /// A spoken clip of six seconds.
    static let clipFR = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/clip-fr.wav")
}

/// Runs `body` on a page of `entry` in a library of its own, closed whatever
/// happens inside.
@MainActor
func withHostedPage(
    _ entry: Entry, engines: Engines? = nil, _ body: (HostedPage) async throws -> Void
) async throws {
    let page = try HostedPage(entry, engines: engines)
    do {
        try await body(page)
    } catch {
        await page.close()
        throw error
    }
    await page.close()
}

/// Waits for the main run loop to finish `count` turns, each up to where it
/// would sleep, and wakes it after each so that an idle loop turns too. What a
/// change sets off, SwiftUI's update of each hosting view and the jobs it
/// leaves to the main actor, runs in the turns that follow it: counted rather
/// than timed, the wait lasts as long as they take on a busy machine.
@MainActor
func turns(_ count: Int) async {
    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
        var left = count
        let main = CFRunLoopGetMain()
        // The largest order: the observers of a turn's end run in increasing order.
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { observer, _ in
            left -= 1
            if left > 0 {
                CFRunLoopWakeUp(main)
            } else {
                CFRunLoopRemoveObserver(main, observer, .commonModes)
                finished.resume()
            }
        }
        CFRunLoopAddObserver(main, observer, .commonModes)
    }
}
