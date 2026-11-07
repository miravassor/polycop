// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What is wrong with a transcript, above its text, on the surface of the work
/// under way. The recording and failures always show, since something does not
/// work until they are dealt with. The checks show as one, or as how many,
/// less those dismissed, which stay in the inspector.
struct EntryNotices: View {
    let entry: Entry
    let findings: Entry.Findings
    let canRebuild: Bool
    let model: AppModel
    let isRunning: Bool
    let engine: Engine?

    var body: some View {
        let checks = TextChecks(
            entry: entry, findings: findings, canRebuild: canRebuild, model: model,
            isRunning: isRunning, engine: engine
        ).aboveText
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
            TextChecksButton(checks: checks) {
                model.setDismissed(checks.map(\.warning), true, on: entry.id)
            }
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

/// How many warnings there are, opening the list of them, with the way to
/// dismiss them all.
struct TextChecksButton: View {
    let checks: [TextCheck]
    let dismissAll: () -> Void
    @State private var isOpen = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: Spacing.icon) {
                    Label("\(checks.count) Warnings", systemImage: NoticeState.warning.symbol)
                        .notice(NoticeState.warning.tint)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                TextChecksList(checks: checks)
            }
            DismissalButton(
                title: "Dismiss All", symbol: "xmark",
                isEnabled: checks.allSatisfy(\.canChangeDismissal), action: dismissAll)
        }
        .statusCapsule()
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
                    DismissalButton(check: check)
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
            TextCheckContent(check: check, shortensTimes: true)
            DismissalButton(check: check)
        }
    }
}

/// Every warning about the text once, in the inspector, those dismissed with
/// the way to bring them back above it.
struct WarningsSection: View {
    let checks: [TextCheck]
    let reading: ReadingSettings

    var body: some View {
        if !checks.isEmpty {
            FoldingSection(.warnings, reading: reading) {
                ForEach(checks) { check in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.icon) {
                        Image(systemName: check.symbol)
                            .foregroundStyle(
                                check.isDismissed
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(NoticeState.warning.tint))
                        TextCheckContent(check: check, actionIsBelow: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        DismissalButton(check: check)
                    }
                }
            }
        }
    }
}

/// Takes warnings off the text, or brings one back.
private struct DismissalButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help(title)
    }
}

extension DismissalButton {
    init(check: TextCheck) {
        self.init(
            title: check.isDismissed ? "Show Above Text" : "Dismiss",
            symbol: check.isDismissed ? "arrow.up.to.line" : "xmark",
            isEnabled: check.canChangeDismissal,
            action: { check.setDismissed(!check.isDismissed) })
    }
}

/// A check's text with its button right after it, or under it where the column
/// is narrow, and the times to listen from.
private struct TextCheckContent: View {
    let check: TextCheck
    var actionIsBelow = false
    var shortensTimes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if actionIsBelow {
                text
                action
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    text
                    action
                }
            }
            if !check.times.isEmpty {
                NoticeTimes(check: check, isShortened: shortensTimes)
            }
        }
    }

    private var text: some View {
        Text(check.text).textSelection(.enabled)
    }

    @ViewBuilder private var action: some View {
        if let action = check.action {
            Button(action.title, action: action.perform)
                .disabled(action.isDisabled)
                .help(action.help ?? Text(""))
        }
    }
}

/// The times a check offers to listen from, in as many rows as they take. Above
/// the text, where each row takes room from the reading, a long list stops at
/// "and N more", which opens all of them.
private struct NoticeTimes: View {
    let check: TextCheck
    let isShortened: Bool

    var body: some View {
        let times = isShortened ? check.shortenedTimes : check.times
        WrappingLayout {
            ForEach(times) { time in
                Button(time.title, action: time.listen)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help(time.help)
            }
            if times.count < check.times.count {
                MoreTimesButton(check: check, hidden: check.times.count - times.count)
            }
        }
        .font(.callout.monospacedDigit())
    }
}

/// How many times a shortened list leaves out, opening the check with all of them.
private struct MoreTimesButton: View {
    let check: TextCheck
    let hidden: Int
    @State private var showsAll = false

    var body: some View {
        Button("and \(hidden) more") { showsAll = true }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .help("Show every time")
            .popover(isPresented: $showsAll, arrowEdge: .bottom) {
                TextChecksList(checks: [check])
            }
    }
}

private let previewChecks = [
    TextCheck(
        warning: .glossary, symbol: "exclamationmark.triangle",
        text: "The glossary could not be read.", isDismissed: false, canChangeDismissal: true,
        setDismissed: { _ in }),
    TextCheck(
        warning: .credits, symbol: "eye.slash",
        text: "2 lines that look like credits were set aside.",
        action: TextCheck.Action(title: "Put Back", help: nil, isDisabled: false, perform: {}),
        isDismissed: true, canChangeDismissal: true, setDismissed: { _ in }),
    TextCheck(
        warning: .resumed, symbol: "arrow.clockwise", text: "Resumed part way.",
        times: (1...12).map {
            TextCheck.Time(title: "00:\($0 + 10):00", help: "Listen from here", listen: {})
        },
        isDismissed: false, canChangeDismissal: true, setDismissed: { _ in }),
]

#Preview("List") {
    TextChecksList(checks: previewChecks)
}

#Preview("Capsules") {
    VStack {
        TextCheckRow(check: previewChecks[1]).statusCapsule()
        TextCheckRow(check: previewChecks[2]).statusCapsule()
        TextChecksButton(checks: previewChecks, dismissAll: {})
    }
    .padding()
}

#Preview("Inspector") {
    Form {
        WarningsSection(checks: previewChecks, reading: ReadingSettings(defaults: MemoryDefaults()))
    }
    .formStyle(.grouped)
    .frame(width: 360)
}
