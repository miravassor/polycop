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
    ("1.0.0", "1.0.0-rc1", true),
    ("1.0.0-rc1", "1.0.0", false),
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

/// The check asks for the repository by number, so a renamed or moved
/// repository still answers, under its new name.
@Test func aRenamedRepositoryStillAnswers() throws {
    #expect(UpdateCheck.latestRelease.path().hasPrefix("/repositories/"))
    let answer = Data(
        #"{"tag_name": "v0.4.0", "html_url": "https://github.com/polycop/app/releases/tag/v0.4.0"}"#
            .utf8)
    #expect(try UpdateCheck.release(from: answer).version == "0.4.0")
}

@Test(arguments: [
    "https://example.com/polycop.zip",
    "http://github.com/miravassor/polycop/releases/tag/v9.0.0",
    "https://github.com/miravassor/polycop/archive/v9.0.0.zip",
])
func onlyAReleasePageOnGitHubIsAccepted(page: String) {
    let answer = Data(#"{"tag_name": "v9.0.0", "html_url": "\#(page)"}"#.utf8)
    #expect(throws: UpdateCheck.Failure.self) { try UpdateCheck.release(from: answer) }
}

/// The system would send the macOS version and the user's languages.
@Test func theRequestNamesOnlyTheApp() {
    let request = UpdateCheck.request(for: UpdateCheck.latestRelease)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Polycop")
    #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
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

/// GitHub limits unauthenticated requests per address, which a campus
/// network can use up.
@Test func aCheckGitHubRefusedRunsAgainAnHourLater() {
    let refused = Date.now
    let last = UpdateSchedule.lastCheck(afterRefusalAt: refused)
    #expect(
        UpdateSchedule.decision(
            allowed: true, launches: 5, lastCheck: last, now: refused.addingTimeInterval(3500))
            == .wait)
    #expect(
        UpdateSchedule.decision(
            allowed: true, launches: 5, lastCheck: last, now: refused.addingTimeInterval(3700))
            == .check)
}

@Test func aRefusedCheckNeverRuns() {
    #expect(
        UpdateSchedule.decision(allowed: false, launches: 9, lastCheck: nil, now: .now) == .wait)
}

/// The test run hosts the app, whose launch must not ask anything.
@MainActor
@Test func theAppKnowsWhenItHostsTests() {
    #expect(PolycopApp.isHostingTests)
}

/// A check counts from when it starts, so one that fails still waits a day;
/// a copy left open checks again when it comes forward a day later, and
/// only a launch asks the question.
@MainActor
@Test func theAutomaticCheckCountsWhenItStartsAndRunsWhenTheAppComesForward() {
    let now = Date.now
    let allowed = MemoryDefaults()
    allowed.set(true, forKey: UpdatePrompt.automaticKey)

    #expect(UpdatePrompt.step(atLaunch: true, defaults: allowed, now: now) == .check)
    #expect(UpdatePrompt.step(atLaunch: true, defaults: allowed, now: now + 60) == .wait)
    #expect(
        UpdatePrompt.step(
            atLaunch: false, defaults: allowed, now: now + UpdateSchedule.interval) == .check)

    let undecided = MemoryDefaults()
    #expect(UpdatePrompt.step(atLaunch: true, defaults: undecided, now: now) == .wait)
    #expect(UpdatePrompt.step(atLaunch: false, defaults: undecided, now: now) == .wait)
    #expect(UpdatePrompt.step(atLaunch: true, defaults: undecided, now: now) == .ask)
}
