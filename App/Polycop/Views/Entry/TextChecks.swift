// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One thing to check about a transcript's text: what it says, where to listen,
/// and what can be done about it.
struct TextCheck: Identifiable {
    struct Time: Identifiable {
        let title: String
        let help: LocalizedStringKey
        let listen: () -> Void
        var id: String { title }
    }

    struct Action {
        let title: LocalizedStringKey
        let help: Text?
        let isDisabled: Bool
        let perform: () -> Void
    }

    let warning: Entry.Warning
    let symbol: String
    let text: String
    var times: [Time] = []
    var action: Action?
    let isDismissed: Bool
    /// False while its transcript runs, whose new text will bring every warning back.
    let canChangeDismissal: Bool
    let setDismissed: (Bool) -> Void
    var id: Entry.Warning { warning }
}

/// The checks on a transcript's text, which the page shows above it and the
/// inspector beside it.
struct TextChecks {
    let entry: Entry
    let findings: Entry.Findings
    /// Whether what a warning offers to rebuild can be, which the page works out.
    let canRebuild: Bool
    let model: AppModel
    let isRunning: Bool
    let engine: Engine?

    /// What shows above the text, the rest staying in the inspector.
    var aboveText: [TextCheck] { all.filter { !$0.isDismissed } }

    /// In the order they matter to reading the text.
    var all: [TextCheck] {
        var checks: [TextCheck] = []
        if let warning = entry.glossaryWarning {
            checks.append(check(.glossary, symbol: NoticeState.warning.symbol, text: warning))
        }
        if let warning = findings.repetitionWarning {
            checks.append(repetition(warning))
        }
        if let times = entry.resumedAt, !times.isEmpty {
            checks.append(
                check(
                    .resumed, symbol: "arrow.clockwise",
                    text: String(
                        localized:
                            "Resumed part way. Words near these points can be missing or repeated:"
                    ),
                    times: times.map { time in
                        TextCheck.Time(
                            title: Transcript.clock(Int(time * 1000)),
                            help: "Listen from ten seconds before",
                            listen: { model.replay(entry.id, from: max(0, time - 10)) })
                    }))
        }
        let gaps = entry.textGaps
        if !gaps.isEmpty {
            checks.append(
                check(
                    .gaps, symbol: "text.badge.xmark",
                    text: String(
                        localized:
                            "No text for a minute or more from these points. A long pause, or speech the model missed: listen to check, or transcribe again with another model."
                    ),
                    times: gaps.map { gap in
                        TextCheck.Time(
                            title:
                                "\(Transcript.clock(Int(gap.lowerBound * 1000))) to \(Transcript.clock(Int(gap.upperBound * 1000)))",
                            help: "Listen from the start of this stretch",
                            listen: { model.replay(entry.id, from: gap.lowerBound) })
                    }))
        }
        if let leftOut = entry.leftOut, let duration = entry.duration {
            let (left, whole) = (formattedDuration(leftOut), formattedDuration(duration))
            checks.append(
                check(
                    .leftOut, symbol: "waveform",
                    text: entry.skipsSilence
                        ? String(
                            localized:
                                "Skip silences left \(left) of this \(whole) recording out of the transcript. Some of it may have been speech."
                        )
                        : String(
                            localized:
                                "Repairing the repeats left \(left) of this \(whole) recording out of the transcript. Some of it may have been speech."
                        )))
        }
        if let text = Credits.notice(findings.hiddenCredits) {
            checks.append(setAside(.credits, text: text))
        }
        if let text = Degeneration.loopNotice(findings.shortenedLoops) {
            checks.append(setAside(.loops, text: text))
        }
        return checks
    }

    private func check(
        _ warning: Entry.Warning, symbol: String, text: String, times: [TextCheck.Time] = [],
        action: TextCheck.Action? = nil
    ) -> TextCheck {
        TextCheck(
            warning: warning, symbol: symbol, text: text, times: times, action: action,
            isDismissed: entry.isDismissed(warning), canChangeDismissal: !isRunning,
            setDismissed: { [model, id = entry.id] in model.setDismissed([warning], $0, on: id) })
    }

    /// Lines kept out of the text, which can be put back.
    private func setAside(_ warning: Entry.Warning, text: String) -> TextCheck {
        check(
            warning, symbol: "eye.slash", text: text,
            action: TextCheck.Action(
                title: "Put Back",
                help: canRebuild
                    ? nil : Text("Putting the lines back would undo your corrections."),
                isDisabled: !canRebuild,
                perform: { [model, id = entry.id] in model.putBackCredits(id) }))
    }

    /// The repeats and the engine are checked here, so only the corrections
    /// decide whether they can be transcribed again.
    private func repetition(_ warning: String) -> TextCheck {
        var action: TextCheck.Action?
        if !findings.repeats.isEmpty, engine?.skipsSilence == true {
            action = TextCheck.Action(
                title: "Transcribe the Repeats Again",
                help: canRebuild
                    ? Text("Skips the silences over those passages only.")
                    : Text("Transcribing them again would undo your corrections."),
                isDisabled: isRunning || !canRebuild || model.stage.isBusy,
                perform: { [model, id = entry.id] in model.repairRepeats(id) })
        }
        return check(
            .repeats, symbol: NoticeState.warning.symbol, text: warning, action: action)
    }
}
