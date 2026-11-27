// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Beside the text, in the system's inspector: the picture of a video, then a
/// grouped form with the export, the warnings about the text, and the settings
/// the transcript was made with. Each section folds.
struct EntryInspector: View {
    let model: AppModel
    let facts: Facts
    /// The size of the recording's picture, nil for sound alone.
    @State private var picture: CGSize?
    /// Where the recording is, found once rather than at each redraw.
    @State private var source: URL?
    @State private var height: CGFloat?
    /// How much of the inspector's height the picture may take, to leave the
    /// settings room at the smallest window, an upright video included.
    private static let pictureShare = 0.55

    /// What the inspector shows of the transcript, which a correction typed in
    /// the text leaves as it is.
    struct Facts: Equatable {
        var id: Entry.ID
        var recording: URL
        var resume: TimeInterval
        var export: EntryExportSection.Facts
        var checks: TextChecks.Facts
        var details: EntryDetails.Facts
    }

    var body: some View {
        // For RedrawTests, in the test host only.
        let _ = Redraws.count(.inspector, in: model)
        VStack(spacing: 0) {
            if let picture, let source {
                VideoSection(
                    model: model, id: facts.id, source: source, picture: picture,
                    resume: facts.resume,
                    tallest: height.map { $0 * Self.pictureShare })
            }
            Form {
                EntryExportSection(model: model, facts: facts.export)
                WarningsSection(
                    checks: TextChecks(facts: facts.checks, model: model).all,
                    reading: model.reading)
                EntryDetails(facts: facts.details, reading: model.reading)
            }
            .formStyle(.grouped)
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            height = $0
        }
        .task(id: facts.recording) {
            guard let entry = model.entry(facts.id) else { return }
            let recording = model.recording(of: entry)
            source = recording
            picture = await Player.pictureSize(of: recording)
            // The picture shows where the reader left off, before playing.
            if picture != nil { model.player.prepare(recording, at: facts.resume) }
        }
    }
}

extension EntryInspector.Facts {
    init(
        entry: Entry, findings: Entry.Findings, textGaps: [ClosedRange<TimeInterval>],
        canRebuild: Bool, lastExport: URL?, model: AppModel
    ) {
        let isRunning = model.busyEntry == entry.id
        self.init(
            id: entry.id,
            recording: entry.recording,
            resume: entry.playbackPosition ?? 0,
            export: EntryExportSection.Facts(
                entry: entry, isRunning: isRunning, lastExport: lastExport),
            checks: TextChecks.Facts(
                entry: entry, findings: findings, textGaps: textGaps, canRebuild: canRebuild,
                isRunning: isRunning, model: model),
            details: EntryDetails.Facts(entry))
    }
}

/// An inspector's width, the same on every page: it starts where the reader
/// left it, since each page has an inspector of its own.
struct InspectorColumn: ViewModifier {
    let layout: WindowLayout

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                layout.inspectorWidth = max($0, EntryView.inspectorWidths.lowerBound)
            }
            .inspectorColumnWidth(
                min: EntryView.inspectorWidths.lowerBound, ideal: layout.inspectorWidth,
                max: EntryView.inspectorWidths.upperBound
            )
    }
}

/// The inspector's button, at the trailing edge of the toolbar above it, the
/// mirror of the library's button at the leading edge. On macOS 26 it has the
/// toolbar's glass only while the inspector is hidden, as the library's has
/// while the library is: over the inspector's own glass it has none. Each
/// page declares it, rather than the inspector's content, where its glass
/// followed the inspector late. Branched here rather than inside the toolbar,
/// where an availability check needs macOS 14.5.
struct InspectorToggle: ViewModifier {
    @Binding var isShown: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem { button }
                    .sharedBackgroundVisibility(isShown ? .hidden : .automatic)
            }
        } else {
            content.toolbar {
                Spacer()
                button
            }
        }
    }

    private var button: some View {
        Button {
            isShown.toggle()
        } label: {
            Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help(isShown ? "Hide the inspector" : "Show the inspector")
    }
}
