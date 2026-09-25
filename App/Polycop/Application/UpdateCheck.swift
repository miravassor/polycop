// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import os

/// Looks up the latest published release on GitHub. It runs only when the user
/// chooses Check for Updates, and the request carries nothing about the Mac or
/// its library.
nonisolated enum UpdateCheck {
    static let latestRelease = URL(
        string: "https://api.github.com/repos/miravassor/polycop/releases/latest")!

    struct Release: Decodable, Equatable {
        let tag: String
        let page: URL

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
        }

        /// The tag without its leading "v", as in "0.2.0".
        var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    }

    enum Failure: LocalizedError {
        case noRelease
        case unavailable(Int)
        case unexpectedPage

        var errorDescription: String? {
            switch self {
            case .noRelease:
                String(localized: "No version of Polycop has been published yet.")
            case .unavailable(let code):
                String(localized: "The release page could not be reached (code \(code)).")
            case .unexpectedPage:
                String(localized: "The answer did not point to the Polycop release page.")
            }
        }
    }

    /// An ephemeral session keeps no cookie or cache between checks.
    static func latest(from url: URL = latestRelease) async throws -> Release {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 200 {
        case 200..<300: return try release(from: data)
        case 404: throw Failure.noRelease
        case let code: throw Failure.unavailable(code)
        }
    }

    /// Only a GitHub page is ever opened from the answer.
    static func release(from data: Data) throws -> Release {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.page.scheme == "https", release.page.host() == "github.com" else {
            throw Failure.unexpectedPage
        }
        return release
    }

    /// Compares dotted version numbers, so "0.10.0" comes after "0.9.1". A
    /// missing component counts as zero, and a suffix such as "-beta" is ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func components(_ version: String) -> [Int] {
            let core = version.split(separator: "-").first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let candidate = components(candidate)
        let current = components(current)
        for index in 0..<max(candidate.count, current.count) {
            let new = index < candidate.count ? candidate[index] : 0
            let old = index < current.count ? current[index] : 0
            if new != old { return new > old }
        }
        return false
    }
}

/// When the automatic check runs: the user is asked once, from the second
/// launch, and a check that is allowed runs at most once a day.
nonisolated enum UpdateSchedule {
    enum Decision: Equatable {
        case ask
        case check
        case wait
    }

    static let interval: TimeInterval = 24 * 60 * 60

    static func decision(allowed: Bool?, launches: Int, lastCheck: Date?, now: Date) -> Decision {
        guard let allowed else { return launches >= 2 ? .ask : .wait }
        guard allowed else { return .wait }
        guard let lastCheck else { return .check }
        return now.timeIntervalSince(lastCheck) >= interval ? .check : .wait
    }
}

/// Runs the checks and answers them in alerts, one check at a time.
enum UpdatePrompt {
    static let automaticKey = "checksForUpdatesAutomatically"
    private static let launchesKey = "launchCount"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedVersion"
    private static var isChecking = false

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A test run hosts the app, which must not ask anything or reach the network.
    static var isHostingTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    /// The Check for Updates command. It always answers, including when the
    /// check fails.
    static func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        let current = currentVersion
        Task {
            defer { isChecking = false }
            do {
                let release = try await UpdateCheck.latest()
                UserDefaults.standard.set(Date.now, forKey: lastCheckKey)
                if UpdateCheck.isNewer(release.version, than: current) {
                    offer(release, current: current, allowsSkipping: false)
                } else {
                    tell(
                        String(localized: "Polycop is up to date"),
                        String(localized: "Version \(current) is the latest."))
                }
            } catch {
                Log.updates.error("the update check failed: \(error, privacy: .private)")
                tell(String(localized: "Could not check for updates"), error.localizedDescription)
            }
        }
    }

    /// Called once per launch. A failure is only logged: the automatic check
    /// never interrupts or blocks anything.
    static func checkAutomaticallyIfDue(defaults: UserDefaults = .standard) {
        guard !isHostingTests else { return }
        let launches = defaults.integer(forKey: launchesKey) + 1
        defaults.set(launches, forKey: launchesKey)
        let decision = UpdateSchedule.decision(
            allowed: defaults.object(forKey: automaticKey) as? Bool, launches: launches,
            lastCheck: defaults.object(forKey: lastCheckKey) as? Date, now: .now)
        switch decision {
        case .wait:
            return
        case .ask:
            let allowed = askToCheckAutomatically()
            defaults.set(allowed, forKey: automaticKey)
            if allowed { checkQuietly(defaults) }
        case .check:
            checkQuietly(defaults)
        }
    }

    private static func checkQuietly(_ defaults: UserDefaults) {
        guard !isChecking else { return }
        isChecking = true
        let current = currentVersion
        Task {
            defer { isChecking = false }
            do {
                let release = try await UpdateCheck.latest()
                defaults.set(Date.now, forKey: lastCheckKey)
                guard UpdateCheck.isNewer(release.version, than: current),
                    release.version != defaults.string(forKey: skippedKey)
                else { return }
                if offer(release, current: current, allowsSkipping: true) == .skip {
                    defaults.set(release.version, forKey: skippedKey)
                }
            } catch {
                Log.updates.info("the automatic update check failed: \(error, privacy: .private)")
            }
        }
    }

    private static func askToCheckAutomatically() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Check for updates automatically?")
        alert.informativeText = String(
            localized:
                "Polycop can ask GitHub once a day whether a newer version is out. The request carries nothing about you or your library. You can change this in Settings."
        )
        alert.addButton(withTitle: String(localized: "Check Automatically"))
        alert.addButton(withTitle: String(localized: "Don't Check"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private enum Choice {
        case download
        case skip
        case later
    }

    @discardableResult
    private static func offer(
        _ release: UpdateCheck.Release, current: String, allowsSkipping: Bool
    ) -> Choice {
        let alert = NSAlert()
        alert.messageText = String(localized: "Polycop \(release.version) is available")
        alert.informativeText = String(
            localized:
                "You have version \(current). The release page has the download and the list of changes."
        )
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addButton(withTitle: String(localized: "Later"))
        if allowsSkipping { alert.addButton(withTitle: String(localized: "Skip This Version")) }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.page)
            return .download
        case .alertThirdButtonReturn:
            return .skip
        default:
            return .later
        }
    }

    private static func tell(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
