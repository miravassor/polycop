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
}
