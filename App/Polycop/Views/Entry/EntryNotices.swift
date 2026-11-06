// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    let symbol: String
    let text: String
    var times: [Time] = []
    var action: Action?
    var id: String { text }
}

/// What is wrong with a transcript, above its text, on the surface of the work
/// under way. The recording and failures always show, since something does not
/// work until they are dealt with. The checks show as one, or as how many.
struct EntryNotices: View {
    let entry: Entry
    let findings: Entry.Findings
    let model: AppModel
    let isRunning: Bool
    let engine: Engine?

    var body: some View {
        let checks = checks
        if !entry.hasRecording || !checks.isEmpty {
            // Side by side when they fit, for the height of the text.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { capsules(checks) }
                VStack(spacing: 8) { capsules(checks) }
            }
        }
        ForEach(
            [model.failure, model.failure(for: entry.id), model.player.failure].compactMap { $0 },
            id: \.self
        ) { failure in
            Notice(failure, .failure)
                .textSelection(.enabled)
                .statusCapsule()
        }
    }

    @ViewBuilder private func capsules(_ checks: [TextCheck]) -> some View {
        if !entry.hasRecording { recording }
        if checks.count == 1, let check = checks.first {
            TextCheckRow(check: check).statusCapsule()
        } else if !checks.isEmpty {
            TextChecksButton(checks: checks)
        }
    }

    /// The details go in the tooltip: the choosing panel opens where it was.
    private var recording: some View {
        HStack(spacing: 12) {
            Label("Recording unavailable", systemImage: "questionmark.folder")
                .notice(.orange)
                .help(
                    "The transcript is safe. Listening, transcribing again and repairing the repeats all need the original recording, last at \(entry.location.path(percentEncoded: false))."
                )
            Button("Locate Recording…") { locateRecording() }
                .disabled(isRunning)
        }
        .statusCapsule()
    }

    /// In the order they matter to reading the text. Internal for its tests.
    var checks: [TextCheck] {
        // Asked once, and only when a check offers to rebuild: the answer runs
        // the course corrections over the whole text.
        let offersRebuild =
            !findings.repeats.isEmpty || !findings.hiddenCredits.isEmpty
            || !findings.shortenedLoops.isEmpty
        let canRebuild = offersRebuild && model.canRebuildParagraphs(of: entry)
        var checks: [TextCheck] = []
        if let warning = entry.glossaryWarning {
            checks.append(TextCheck(symbol: NoticeState.warning.symbol, text: warning))
        }
        if let warning = findings.repetitionWarning {
            checks.append(repetition(warning, canRebuild: canRebuild))
        }
        if let times = entry.resumedAt, !times.isEmpty {
            checks.append(
                TextCheck(
                    symbol: "arrow.clockwise",
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
                TextCheck(
                    symbol: "text.badge.xmark",
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
                TextCheck(
                    symbol: "waveform",
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
        let hidden = [
            Credits.notice(findings.hiddenCredits),
            Degeneration.loopNotice(findings.shortenedLoops),
        ]
        for text in hidden.compactMap({ $0 }) {
            checks.append(
                TextCheck(
                    symbol: "eye.slash", text: text,
                    action: TextCheck.Action(
                        title: "Put Back",
                        help: canRebuild
                            ? nil : Text("Putting the lines back would undo your corrections."),
                        isDisabled: !canRebuild,
                        perform: { model.putBackCredits(entry.id) })))
        }
        return checks
    }

    /// The repeats and the engine are checked here, so only the corrections
    /// decide whether they can be transcribed again.
    private func repetition(_ warning: String, canRebuild: Bool) -> TextCheck {
        var check = TextCheck(symbol: NoticeState.warning.symbol, text: warning)
        if !findings.repeats.isEmpty, engine?.skipsSilence == true {
            check.action = TextCheck.Action(
                title: "Transcribe the Repeats Again",
                help: canRebuild
                    ? Text("Skips the silences over those passages only.")
                    : Text("Transcribing them again would undo your corrections."),
                isDisabled: isRunning || !canRebuild || model.stage.isBusy,
                perform: { model.repairRepeats(entry.id) })
        }
        return check
    }

    /// Where the recording went. Nothing is transcribed again: the transcript
    /// only needs its audio back to be listened to.
    private func locateRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose the recording this transcript was made from.")
        panel.directoryURL = entry.location.deletingLastPathComponent()
        guard panel.runModal() == .OK, let found = panel.url else { return }
        model.locateRecording(entry.id, at: found)
    }
}

/// How many checks there are, opening the list of them.
struct TextChecksButton: View {
    let checks: [TextCheck]
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: Spacing.icon) {
                Label("\(checks.count) Things to Check", systemImage: NoticeState.warning.symbol)
                    .notice(NoticeState.warning.tint)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .statusCapsule()
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            TextChecksList(checks: checks)
        }
    }
}

/// Every check, the symbols in one column so that the text starts level.
struct TextChecksList: View {
    let checks: [TextCheck]

    var body: some View {
        Grid(
            alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.icon,
            verticalSpacing: 12
        ) {
            ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                // Outside a row it spans the columns; unsized, it does not widen them.
                if index > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    Image(systemName: check.symbol)
                        .foregroundStyle(NoticeState.warning.tint)
                        .gridColumnAlignment(.center)
                    TextCheckContent(check: check)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.callout)
        .padding(20)
        // A popover would cut its text to one line. Only here: on the page, this
        // lets the column outgrow the window and takes the player out of it.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 440, alignment: .leading)
    }
}

/// One check with its symbol, alone on the page.
struct TextCheckRow: View {
    let check: TextCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.icon) {
            Image(systemName: check.symbol).foregroundStyle(NoticeState.warning.tint)
            TextCheckContent(check: check)
        }
    }
}

/// A check's text with its button right after it, and the times to listen from.
private struct TextCheckContent: View {
    let check: TextCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(check.text)
                    .textSelection(.enabled)
                if let action = check.action {
                    Button(action.title, action: action.perform)
                        .disabled(action.isDisabled)
                        .help(action.help ?? Text(""))
                }
            }
            if !check.times.isEmpty {
                NoticeTimes(times: check.times)
            }
        }
    }
}

/// The times a check offers to listen from, on one line that scrolls only when
/// they do not fit.
private struct NoticeTimes: View {
    let times: [TextCheck.Time]

    var body: some View {
        let row = HStack {
            ForEach(times) { time in
                Button(time.title, action: time.listen)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help(time.help)
            }
        }
        .font(.callout.monospacedDigit())
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal) { row }
        }
    }
}

private let previewChecks = [
    TextCheck(symbol: "exclamationmark.triangle", text: "The glossary could not be read."),
    TextCheck(
        symbol: "eye.slash", text: "2 lines that look like credits were set aside.",
        action: TextCheck.Action(title: "Put Back", help: nil, isDisabled: false, perform: {})),
]

#Preview("List") {
    TextChecksList(checks: previewChecks)
}

#Preview("Capsules") {
    VStack {
        TextCheckRow(check: previewChecks[1]).statusCapsule()
        TextChecksButton(checks: previewChecks)
    }
    .padding()
}
