// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@testable import Polycop

/// The scenes `Tools/scenes.sh` can capture. A pull request that adds a state
/// a reader can meet adds its scene here.
extension Scene {
    static let all: [Scene] = [
        Scene(name: "new-transcription") { $0.model.pane = .new },
        Scene(name: "transcript") { stage in
            stage.finish(stage.first)
            stage.change(stage.first) { $0.playbackPosition = 2268 }
            stage.model.pane = .entry(stage.first)
        },
        Scene(name: "transcribing") { stage in
            stage.model.running = stage.first
            stage.change(stage.first) {
                $0.state = .running
                $0.duration = 5400
                $0.paragraphs = Array(Scene.text.prefix(12))
            }
            stage.model.stage = .transcribing(0.42)
            stage.model.pane = .entry(stage.first)
        },
        Scene(name: "paused") { stage in
            stage.model.running = stage.first
            stage.change(stage.first) {
                $0.state = .running
                $0.duration = 5400
                $0.paragraphs = Array(Scene.text.prefix(12))
            }
            stage.model.stage = .paused(0.42)
            stage.model.pane = .entry(stage.first)
        },
        Scene(name: "waiting-its-turn") { stage in
            stage.model.running = stage.first
            stage.change(stage.first) { $0.state = .running }
            stage.model.stage = .transcribing(0.42)
            stage.model.pane = .entry(stage.second)
        },
        Scene(name: "stopped") { stage in
            stage.change(stage.first) {
                $0.state = .stopped
                $0.duration = 5400
                $0.paragraphs = Array(Scene.text.prefix(2))
            }
            stage.model.pane = .entry(stage.first)
        },
        Scene(name: "failed") { stage in
            stage.change(stage.first) { $0.state = .failed("The recording could not be read.") }
            stage.model.pane = .entry(stage.first)
        },
        Scene(name: "warnings") { stage in
            stage.finish(stage.first)
            stage.change(stage.first) {
                $0.glossaryWarning = "The glossary of this course could not be read."
                $0.resumedAt = [612, 1840]
            }
            stage.model.pane = .entry(stage.first)
        },
        Scene(
            name: "selection",
            arrange: { stage in
                stage.finish(stage.first)
                stage.model.pane = .entry(stage.first)
            },
            act: { window in
                guard let page = window.contentView else { return }
                for (paragraph, range) in zip(paragraphs(in: page), [8..<30, 31..<55]) {
                    window.makeFirstResponder(paragraph)
                    paragraph.setSelectedRange(NSRange(range))
                }
            }),
    ]

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
