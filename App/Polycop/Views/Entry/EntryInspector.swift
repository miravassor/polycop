// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Beside the text, in the system's inspector: the picture of a video, how the
/// page follows playback, the export, and the settings the transcript was made
/// with. A grouped form as in Settings, so every control sits on a row of its
/// own section, label at the leading edge and control at the trailing one. The
/// player itself, with its paragraph steps, stays under the text, inspector or
/// not.
struct EntryInspector: View {
    let model: AppModel
    let entry: Entry
    @Binding var following: Following
    @Binding var isFollowSuspended: Bool
    /// Whether any word has a time, which the highlight and the cursor need.
    let hasTimedWords: Bool
    let isRunning: Bool
    let engine: Engine?
    /// The size of the recording's picture, nil for sound alone.
    @State private var picture: CGSize?
    /// Where the recording is, found once rather than at each redraw.
    @State private var source: URL?

    var body: some View {
        Form {
            if let picture, let source {
                VideoSection(
                    model: model, id: entry.id, source: source, picture: picture,
                    resume: entry.playbackPosition ?? 0)
            }
            if !entry.paragraphs.isEmpty {
                Section("Playback") { follow }
            }
            EntryExportSection(model: model, entry: entry, isRunning: isRunning)
            EntryDetails(entry: entry, engine: engine)
        }
        .formStyle(.grouped)
        .task(id: entry.recording) {
            let recording = model.recording(of: entry)
            source = recording
            picture = await Player.pictureSize(of: recording)
            // The picture shows where the reader left off, before playing.
            if picture != nil { model.player.prepare(recording, at: entry.playbackPosition ?? 0) }
        }
    }

    /// Follow's choice, or the way back to playback once the reader has
    /// scrolled away from it, on the same row.
    @ViewBuilder private var follow: some View {
        if isFollowSuspended {
            LabeledContent("Follow") {
                Button("Return to Playback", systemImage: "arrow.uturn.backward") {
                    isFollowSuspended = false
                }
                .disabled(!model.player.isOpen)
            }
        } else {
            Picker("Follow", selection: $following) {
                ForEach(Following.allCases, id: \.self) { choice in
                    Text(choice.name)
                        .tag(choice)
                        .selectionDisabled(choice == .cursor && !hasTimedWords)
                }
            }
            .pickerStyle(.menu)
            .help(
                hasTimedWords
                    ? "Page scrolls to the paragraph being played. Page and Cursor also takes the text cursor along with the word heard."
                    : "Page scrolls to the paragraph being played. This transcript has no word timings, so the word heard is not highlighted and the cursor cannot follow it."
            )
        }
    }
}

/// An inspector's width and button, the same on every page: it starts where
/// the reader left it, since each page has an inspector of its own.
struct InspectorColumn: ViewModifier {
    @Binding var isShown: Bool
    @Binding var width: Double

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = max($0, EntryView.inspectorWidths.lowerBound)
            }
            .inspectorColumnWidth(
                min: EntryView.inspectorWidths.lowerBound, ideal: width,
                max: EntryView.inspectorWidths.upperBound
            )
            .modifier(InspectorToggle(isShown: $isShown))
    }
}
