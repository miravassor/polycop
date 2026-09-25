// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

@Test(arguments: [
    ("0.3.0", "0.2.0", true),
    ("0.2.1", "0.2.0", true),
    ("0.10.0", "0.9.1", true),
    ("1.0", "0.9.9", true),
    ("0.2.0", "0.2.0", false),
    ("0.2", "0.2.0", false),
    ("0.1.9", "0.2.0", false),
    ("0.3.0-beta", "0.2.0", true),
])
func versionsCompareNumerically(candidate: String, current: String, isNewer: Bool) {
    #expect(UpdateCheck.isNewer(candidate, than: current) == isNewer)
}

/// The fields GitHub returns for a release, trimmed to a few of them.
@Test func aReleaseIsReadFromGitHubsAnswer() throws {
    let answer = Data(
        """
        {"tag_name": "v0.3.0", "name": "Polycop 0.3.0", "draft": false,
         "html_url": "https://github.com/miravassor/polycop/releases/tag/v0.3.0"}
        """.utf8)
    let release = try UpdateCheck.release(from: answer)
    #expect(release.version == "0.3.0")
    #expect(release.page.absoluteString.hasSuffix("/releases/tag/v0.3.0"))
}

@Test func onlyAGitHubPageIsAccepted() {
    let answer = Data(
        #"{"tag_name": "v9.0.0", "html_url": "https://example.com/polycop.zip"}"#.utf8)
    #expect(throws: UpdateCheck.Failure.self) { try UpdateCheck.release(from: answer) }
}

@Test func theAutomaticCheckIsOfferedFromTheSecondLaunch() {
    let now = Date.now
    #expect(UpdateSchedule.decision(allowed: nil, launches: 1, lastCheck: nil, now: now) == .wait)
    #expect(UpdateSchedule.decision(allowed: nil, launches: 2, lastCheck: nil, now: now) == .ask)
}

@Test func anAllowedCheckRunsAtMostOnceADay() {
    let now = Date.now
    let hourAgo = now.addingTimeInterval(-3600)
    let dayAgo = now.addingTimeInterval(-UpdateSchedule.interval)
    #expect(UpdateSchedule.decision(allowed: true, launches: 5, lastCheck: nil, now: now) == .check)
    #expect(
        UpdateSchedule.decision(allowed: true, launches: 5, lastCheck: hourAgo, now: now) == .wait)
    #expect(
        UpdateSchedule.decision(allowed: true, launches: 5, lastCheck: dayAgo, now: now) == .check)
}

@Test func aRefusedCheckNeverRuns() {
    #expect(
        UpdateSchedule.decision(allowed: false, launches: 9, lastCheck: nil, now: .now) == .wait)
}

/// The test run hosts the app, whose launch must not ask anything.
@MainActor
@Test func theAppKnowsWhenItHostsTests() {
    #expect(UpdatePrompt.isHostingTests)
}
