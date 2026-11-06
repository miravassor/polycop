// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Polycop

/// A finished transcript in a folder of its own, its recording there.
@MainActor
private struct Page {
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let model: AppModel

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model = AppModel(history: folder.appending(path: "History"))
    }

    func checks(_ change: (inout Entry) -> Void = { _ in }) -> [TextCheck] {
        var entry = Entry(
            recording: folder.appending(path: "lecture.wav"),
            modelFile: ModelCatalog.recommended.id, glossary: nil, skipsSilence: false,
            subtitles: false)
        entry.state = .finished
        change(&entry)
        return EntryNotices(
            entry: entry, findings: entry.findings, model: model, isRunning: false, engine: nil
        ).checks
    }

    func clear() { try? FileManager.default.removeItem(at: folder) }
}

@MainActor
@Suite struct TextChecksOfATranscript {
    @Test func aCleanTranscriptHasNone() throws {
        let page = try Page()
        defer { page.clear() }
        #expect(page.checks().isEmpty)
    }

    /// Each keeps its own symbol, and a resumed point can be listened to.
    @Test func eachSaysWhatItIsAndWhereToListen() throws {
        let page = try Page()
        defer { page.clear() }
        let checks = page.checks {
            $0.glossaryWarning = "The glossary could not be read."
            $0.resumedAt = [612, 1840]
        }
        #expect(checks.map(\.symbol) == ["exclamationmark.triangle", "arrow.clockwise"])
        #expect(checks[0].text == "The glossary could not be read.")
        #expect(checks[1].times.map(\.title) == ["00:10:12", "00:30:40"])
    }

    /// The list identifies them by their text, so none may be lost to another.
    @Test func noTwoShareAnIdentity() throws {
        let page = try Page()
        defer { page.clear() }
        let checks = page.checks {
            $0.glossaryWarning = "The glossary could not be read."
            $0.resumedAt = [612]
            $0.duration = 600
            $0.decoded = [Segment(start: 0, end: 10, text: "Bonjour à tous.")]
        }
        #expect(checks.count == 3)
        #expect(Set(checks.map(\.id)).count == checks.count)
    }
}
