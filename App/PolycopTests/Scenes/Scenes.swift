// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@testable import Polycop

/// The scenes `Tools/scenes.sh` can capture. A pull request that adds a state
/// a reader can meet adds its scene here.
extension AppScene {
    static let all: [AppScene] = [
        AppScene(name: "new-transcription") { $0.model.pane = .new },
        AppScene(name: "no-model") { stage in
            stage.engines.installed = []
            stage.model.refreshInstalled()
            stage.model.pane = .new
        },
        AppScene(name: "transcript") { stage in
            stage.finish(stage.first)
            stage.change(stage.first) { $0.playbackPosition = 700 }
            stage.model.pane = .entry(stage.first)
        },
        // A lecture of an hour and a half, with a paragraph every few points
        // of the player's timeline.
        AppScene(name: "long-lecture") { stage in
            let lengths: [Double] = [18, 42, 27, 65, 33, 51, 22, 74, 38, 46]
            var segments: [Segment] = []
            while (segments.last?.end ?? 0) < 5400 {
                let start = segments.last?.end ?? 0
                segments.append(
                    Segment(
                        start: start, end: start + lengths[segments.count % lengths.count],
                        text: AppScene.sentences[segments.count % 4]))
            }
            stage.change(stage.first) {
                $0.state = .finished
                $0.duration = segments.last?.end
                $0.decoded = segments
                $0.paragraphs = segments.map {
                    Transcript.Paragraph(start: Int($0.start * 1000), text: $0.text)
                }
                $0.playbackPosition = 2000
            }
            stage.model.pane = .entry(stage.first)
        },
        AppScene(name: "transcribing") { stage in
            stage.model.running = stage.first
            stage.change(stage.first) {
                $0.state = .running
                $0.duration = AppScene.length
                $0.paragraphs = Array(AppScene.text.prefix(12))
            }
            stage.model.stage = .transcribing(0.42)
            stage.model.pane = .entry(stage.first)
        },
        AppScene(name: "paused") { stage in
            stage.model.running = stage.first
            stage.change(stage.first) {
                $0.state = .running
                $0.duration = AppScene.length
                $0.paragraphs = Array(AppScene.text.prefix(12))
            }
            stage.model.stage = .paused(0.42)
            stage.model.pane = .entry(stage.first)
        },
        AppScene(name: "waiting-its-turn") { stage in
            stage.model.running = stage.first
            stage.model.scheduled = [stage.second]
            stage.change(stage.first) { $0.state = .running }
            stage.model.stage = .transcribing(0.42)
            stage.model.pane = .entry(stage.second)
        },
        AppScene(name: "stopped") { stage in
            stage.change(stage.first) {
                $0.state = .stopped
                $0.duration = AppScene.length
                $0.decoded = Array(AppScene.segments.prefix(2))
                $0.paragraphs = Array(AppScene.text.prefix(2))
            }
            stage.model.pane = .entry(stage.first)
        },
        AppScene(name: "failed") { stage in
            stage.change(stage.first) { $0.state = .failed("The recording could not be read.") }
            stage.model.pane = .entry(stage.first)
        },
        AppScene(name: "warnings") { stage in
            stage.finish(stage.first)
            stage.change(stage.first) {
                $0.glossaryWarning = "The glossary of this course could not be read."
                $0.resumedAt = [612, 1240]
            }
            stage.model.pane = .entry(stage.first)
        },
        AppScene(
            name: "selection",
            arrange: { stage in
                stage.finish(stage.first)
                stage.model.pane = .entry(stage.first)
            },
            act: { window in
                guard let page = window.contentView, let paragraph = paragraphs(in: page).first
                else { return }
                window.makeFirstResponder(paragraph)
                paragraph.setSelectedRange(NSRange(8..<30))
            }),
        AppScene(name: "library") { stage in
            arrangeLibrary(stage)
        },
        AppScene(name: "library-collapsed") { stage in
            arrangeLibrary(stage)
            if let extra = stage.model.duplicate(stage.second),
                let longCourse = try? stage.model.createFolder(
                    named: "Constitutional History Seminar")
            {
                stage.change(extra) { $0.title = "Extra reading" }
                try? stage.model.setFolderColor(longCourse, to: .red)
                stage.model.moveEntry(extra, to: longCourse)
                stage.model.clearFlairs(on: [extra])
                stage.model.toggleFlair(.done, on: [extra])
                stage.model.toggleFlair(.exam, on: [extra])
                stage.model.addCustomTag(named: "Midterm", color: .blue, to: [extra])
                stage.model.addCustomTag(named: "Cases", color: .purple, to: [extra])
                stage.model.toggleFlair(
                    TranscriptFlair(kind: nil, title: "", color: .yellow), on: [extra]
                )
            }
            stage.model.layout.openFolders = []
        },
        AppScene(name: "library-filtered") { stage in
            arrangeLibrary(stage)
            stage.model.layout.filter = .unreviewed
            stage.model.layout.openFolders = []
        },
    ]

    private static func arrangeLibrary(_ stage: Stage) {
        stage.finish(stage.first)
        stage.finish(stage.second)
        stage.change(stage.first) { $0.title = "Lecture 10" }
        stage.change(stage.second) { $0.title = "Lecture 2" }
        let third = stage.model.duplicate(stage.second)
        if let third {
            stage.change(third) { $0.title = "Seminar notes" }
        }
        do {
            let law = try stage.model.createFolder(named: "Law")
            try stage.model.setFolderColor(law, to: .purple)
            let history = try stage.model.createFolder(named: "History")
            try stage.model.setFolderColor(history, to: .orange)
            let biology = try stage.model.createFolder(named: "Biology")
            try stage.model.setFolderColor(biology, to: .green)
            let lectures = try stage.model.createFolder(named: "Lectures", in: biology)
            try stage.model.setFolderColor(lectures, to: .blue)
            stage.model.moveEntry(stage.first, to: history)
            stage.model.moveEntry(stage.second, to: history)
            if let third {
                stage.model.moveEntry(third, to: lectures)
                stage.model.setPinned([third], to: true)
                stage.model.toggleFlair(.urgent, on: [third])
            }
            stage.model.toggleFlair(.done, on: [stage.second])
            stage.model.toggleFlair(.exam, on: [stage.second])
            stage.model.toggleFlair(.todo, on: [stage.first])
            stage.model.addCustomTag(named: "Midterm", color: .blue, to: [stage.first])
            stage.model.layout.openFolders = [biology, lectures, history]
        } catch {
            assertionFailure("\(error)")
        }
        stage.model.layout.sort = .name
        stage.model.layout.showsLibrary = true
        stage.model.pane = .entry(stage.second)
    }

    /// The paragraphs on screen, from the top of the page down.
    private static func paragraphs(in view: NSView) -> [WordTextView] {
        func all(_ view: NSView) -> [WordTextView] {
            (view as? WordTextView).map { [$0] } ?? view.subviews.flatMap(all)
        }
        return all(view)
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }
}
