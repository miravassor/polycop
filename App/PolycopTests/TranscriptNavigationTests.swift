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
}
