// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Testing

@testable import Polycop

@Suite struct TranscriptNavigationTests {
    @Test(arguments: [
        (20.0, 40.0, false),
        (-10.0, 40.0, true),
        (280.0, 40.0, true),
        (20.0, 900.0, false),
        (250.0, 900.0, true),
    ])
    func scrollOnlyWhenOpeningLinesAreHidden(top: Double, height: Double, expected: Bool) {
        #expect(
            TranscriptNavigation.needsScroll(
                frame: CGRect(x: 0, y: top, width: 600, height: height), height: 300) == expected)
    }

    @Test func thePlayingParagraphIsTheLastOneStarted() {
        let starts: [TimeInterval] = [0, 10, 20]
        #expect(TranscriptNavigation.paragraph(playingAt: 15, starts: starts) == 1)
        #expect(TranscriptNavigation.paragraph(playingAt: 19.6, starts: starts) == 2)
        #expect(TranscriptNavigation.paragraph(playingAt: 0, starts: []) == nil)
    }

    @Test(arguments: [
        (current: Int?.none, offset: 1, expected: Int?.some(0)),
        (current: Int?.none, offset: -1, expected: Int?.some(0)),
        (current: Int?.some(1), offset: 1, expected: Int?.some(2)),
        (current: Int?.some(1), offset: -1, expected: Int?.some(0)),
        (current: Int?.some(2), offset: 1, expected: Int?.some(2)),
        (current: Int?.some(0), offset: -1, expected: Int?.some(0)),
    ])
    func steppingStaysInsideTheTranscript(current: Int?, offset: Int, expected: Int?) {
        #expect(TranscriptNavigation.paragraph(from: current, offset: offset, count: 3) == expected)
    }

    @Test func revealParagraphsOutsideTheLazyStack() {
        #expect(TranscriptNavigation.needsScroll(frame: nil, height: 300))
    }

    @MainActor
    @Test func onlyManualScrollingInThisTranscriptSuspendsFollowing() {
        let scroll = NSScrollView()
        let other = NSScrollView()
        var suspensions = 0
        let observer = ManualScroll.Observer { suspensions += 1 }
        scroll.documentView = observer

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification, object: other)
        #expect(suspensions == 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 50))
        #expect(suspensions == 0)
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(suspensions == 1)
        scroll.documentView = nil
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(suspensions == 1)
    }

    /// The row at the top of the page is the one across its top edge, or the
    /// next one once the edge falls in the spacing between them.
    @Test func theRowAtTheTopIsTheOneAcrossTheEdge() {
        func row(_ top: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: 0, y: top, width: 400, height: height)
        }
        #expect(TranscriptNavigation.isAtTop(row(-100, 150), spacing: 20))
        #expect(!TranscriptNavigation.isAtTop(row(70, 100), spacing: 20))
        #expect(!TranscriptNavigation.isAtTop(row(-160, 150), spacing: 20))
        #expect(TranscriptNavigation.isAtTop(row(10, 100), spacing: 20))
        #expect(TranscriptNavigation.isAtTop(row(0, 100), spacing: 20))
    }

    @Test func aStepBackHearsTheParagraphAgainThenGoesBackOne() {
        let starts: [TimeInterval] = [0, 40, 90]
        // Well into the second paragraph: from its start.
        #expect(TranscriptNavigation.paragraph(steppingBackAt: 60, starts: starts) == 1)
        // In its first seconds, and in the lead-in a replay starts with: the one before.
        #expect(TranscriptNavigation.paragraph(steppingBackAt: 41, starts: starts) == 0)
        #expect(TranscriptNavigation.paragraph(steppingBackAt: 39.6, starts: starts) == 0)
        // The first paragraph has none before it.
        #expect(TranscriptNavigation.paragraph(steppingBackAt: 1, starts: starts) == 0)
        #expect(TranscriptNavigation.paragraph(steppingBackAt: 20, starts: starts) == 0)
        #expect(TranscriptNavigation.paragraph(steppingBackAt: 5, starts: []) == nil)
    }

    /// Coming back always has somewhere to go, even before the first paragraph
    /// opens, where nothing is playing yet.
    @Test func returningGoesToThePlayingParagraphOrTheFirst() {
        let starts: [TimeInterval] = [40, 80, 120]
        #expect(TranscriptNavigation.paragraph(returningTo: 90, starts: starts) == 1)
        #expect(TranscriptNavigation.paragraph(returningTo: 0, starts: starts) == 0)
        #expect(TranscriptNavigation.paragraph(returningTo: 0, starts: []) == nil)
    }

    /// A transcript with no word timings gives the cursor nothing to follow, so
    /// a click must stop the page, or it would scroll away from the correction.
    @Test func withoutWordTimingsThePageFollowsAlone() {
        #expect(Following.cursor.effective(hasTimedWords: true) == .cursor)
        #expect(Following.cursor.effective(hasTimedWords: false) == .page)
        #expect(Following.off.effective(hasTimedWords: false) == .off)
    }

    /// A flick coasts on after the fingers lift: that is not the reader
    /// scrolling again, and would stop the page they just brought back.
    @MainActor
    @Test func aFlickCoastingIsNotTheReaderScrolling() throws {
        func event(momentum: Int64) throws -> NSEvent {
            let scroll = try #require(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10,
                    wheel2: 0, wheel3: 0))
            scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return try #require(NSEvent(cgEvent: scroll))
        }
        #expect(ManualScroll.Observer.isReaderScrolling(try event(momentum: 0)))
        #expect(!ManualScroll.Observer.isReaderScrolling(try event(momentum: 2)))
    }

    /// Follow and the way back stay in reach with the toolbar hidden; with
    /// nothing open, as in the test host, the way back leads nowhere.
    @MainActor
    @Test func thePlaybackMenuHoldsFollowAndTheWayBack() throws {
        let menu = try #require(NSApp.mainMenu?.item(withTitle: "Playback")?.submenu)
        menu.update()
        for choice in Following.allCases {
            #expect(menu.item(withTitle: choice.name) != nil)
        }
        let back = try #require(menu.item(withTitle: "Return to Playback"))
        #expect(!back.isEnabled)
        #expect(back.keyEquivalent == "l")
        #expect(back.keyEquivalentModifierMask == [.command, .option])
    }

    /// Following the cursor is for editing, so a click in the text no longer
    /// stops the page; following the page alone still steps aside.
    @Test func editingStopsThePageUnlessTheCursorFollows() {
        #expect(Following.page.stopsWhenEditing)
        #expect(!Following.cursor.stopsWhenEditing)
    }
}
