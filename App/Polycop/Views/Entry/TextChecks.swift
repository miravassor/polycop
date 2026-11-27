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

    /// The times where room is short. One over the limit still shows, since
    /// "and 1 more" would take its place.
    var shortenedTimes: [Time] {
        let limit = 4
        return times.count > limit + 1 ? Array(times.prefix(limit)) : times
    }
}

/// The checks on a transcript's text, which the page shows above it and the
/// inspector beside it.
struct TextChecks {
    /// What the warnings read of the transcript and the model, which a
    /// correction typed in the text and a progress tick leave as they are.
    struct Facts: Equatable {
        var id: Entry.ID
        var glossaryWarning: String?
        var findings: Entry.Findings
        var resumedAt: [TimeInterval]?
        var textGaps: [ClosedRange<TimeInterval>]
        var leftOut: TimeInterval?
        var duration: TimeInterval?
        var skipsSilence: Bool
        var dismissedWarnings: Set<String>?
        /// Whether what a warning offers to rebuild can be, which the page works out.
        var canRebuild: Bool
        var isRunning: Bool
        /// Whether other work is under way, which the repeats' fix waits for.
        /// False where that fix does not show, so that work starting or ending
        /// on another recording leaves these facts equal.
        var isBusy: Bool
        var engineSkipsSilence: Bool

        /// Whether the repeats can be transcribed again: only the corrections
        /// then decide whether they may be.
        var offersRepeatsRepair: Bool {
            findings.repetitionWarning != nil && !findings.repeats.isEmpty
                && engineSkipsSilence
        }

        func isDismissed(_ warning: Entry.Warning) -> Bool {
            dismissedWarnings?.contains(warning.rawValue) == true
        }
    }

    let facts: Facts
    let model: AppModel

    /// What shows above the text, the rest staying in the inspector.
    var aboveText: [TextCheck] { all.filter { !$0.isDismissed } }

    /// In the order they matter to reading the text.
    var all: [TextCheck] {
        var checks: [TextCheck] = []
        if let warning = facts.glossaryWarning {
            checks.append(check(.glossary, symbol: NoticeState.warning.symbol, text: warning))
        }
        if let warning = facts.findings.repetitionWarning {
            checks.append(repetition(warning))
        }
        if let times = facts.resumedAt, !times.isEmpty {
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
                            listen: { [model, id = facts.id] in
                                model.replay(id, from: max(0, time - 10))
                            })
                    }))
        }
        if !facts.textGaps.isEmpty {
            checks.append(
                check(
                    .gaps, symbol: "text.badge.xmark",
                    text: String(
                        localized:
                            "No text for a minute or more from these points. A long pause, or speech the model missed: listen to check, or transcribe again with another model."
                    ),
                    times: facts.textGaps.map { gap in
                        TextCheck.Time(
                            title:
                                "\(Transcript.clock(Int(gap.lowerBound * 1000))) to \(Transcript.clock(Int(gap.upperBound * 1000)))",
                            help: "Listen from the start of this stretch",
                            listen: { [model, id = facts.id] in
                                model.replay(id, from: gap.lowerBound)
                            })
                    }))
        }
        if let leftOut = facts.leftOut, let duration = facts.duration {
            let (left, whole) = (formattedDuration(leftOut), formattedDuration(duration))
            checks.append(
                check(
                    .leftOut, symbol: "waveform",
                    text: facts.skipsSilence
                        ? String(
                            localized:
                                "Skip silences left \(left) of this \(whole) recording out of the transcript. Some of it may have been speech."
                        )
                        : String(
                            localized:
                                "Repairing the repeats left \(left) of this \(whole) recording out of the transcript. Some of it may have been speech."
                        )))
        }
        if let text = Credits.notice(facts.findings.hiddenCredits) {
            checks.append(setAside(.credits, text: text))
        }
        if let text = Degeneration.loopNotice(facts.findings.shortenedLoops) {
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
            isDismissed: facts.isDismissed(warning), canChangeDismissal: !facts.isRunning,
            setDismissed: { [model, id = facts.id] in model.setDismissed([warning], $0, on: id) })
    }

    /// Lines kept out of the text, which can be put back.
    private func setAside(_ warning: Entry.Warning, text: String) -> TextCheck {
        check(
            warning, symbol: "eye.slash", text: text,
            action: TextCheck.Action(
                title: "Put Back",
                help: facts.canRebuild
                    ? nil : Text("Putting the lines back would undo your corrections."),
                isDisabled: !facts.canRebuild,
                perform: { [model, id = facts.id] in model.putBackCredits(id) }))
    }

    private func repetition(_ warning: String) -> TextCheck {
        var action: TextCheck.Action?
        if facts.offersRepeatsRepair {
            action = TextCheck.Action(
                title: "Transcribe the Repeats Again",
                help: facts.canRebuild
                    ? Text("Skips the silences over those passages only.")
                    : Text("Transcribing them again would undo your corrections."),
                isDisabled: facts.isRunning || !facts.canRebuild || facts.isBusy,
                perform: { [model, id = facts.id] in model.repairRepeats(id) })
        }
        return check(
            .repeats, symbol: NoticeState.warning.symbol, text: warning, action: action)
    }
}

extension TextChecks.Facts {
    init(
        entry: Entry, findings: Entry.Findings, textGaps: [ClosedRange<TimeInterval>],
        canRebuild: Bool, isRunning: Bool, model: AppModel
    ) {
        let engine = ModelCatalog.model(entry.modelFile)?.engine
        self.init(
            id: entry.id, glossaryWarning: entry.glossaryWarning, findings: findings,
            resumedAt: entry.resumedAt, textGaps: textGaps, leftOut: entry.leftOut,
            duration: entry.duration, skipsSilence: entry.skipsSilence,
            dismissedWarnings: entry.dismissedWarnings, canRebuild: canRebuild,
            isRunning: isRunning, isBusy: false,
            engineSkipsSilence: engine?.skipsSilence == true)
        if offersRepeatsRepair { isBusy = model.isBusy }
    }
}
