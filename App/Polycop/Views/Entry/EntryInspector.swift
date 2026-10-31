// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Beside the text, in the system's inspector: the picture of a video, moving
/// through the paragraphs while listening, and the export. A grouped form as
/// in Settings, so every control sits on a row of its own section, label at
/// the leading edge and control at the trailing one. The player itself stays
/// under the text, inspector or not.
struct EntryInspector: View {
    let model: AppModel
    let entry: Entry
    let steps: ParagraphSteps
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
                Section("Video") {
                    EntryVideo(
                        model: model, id: entry.id, source: source, picture: picture,
                        resume: entry.playbackPosition ?? 0)
                    VideoControls(model: model)
                }
            }
            if !entry.paragraphs.isEmpty {
                Section("Playback") {
                    follow
                    HStack(spacing: 8) {
                        step("Previous", systemImage: "chevron.up", by: -1)
                        replayPassage
                        step("Next", systemImage: "chevron.down", by: 1)
                    }
                }
            }
            EntryExportSection(model: model, entry: entry, isRunning: isRunning, engine: engine)
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

    /// The shortcuts are the Playback menu's, which work with the inspector
    /// hidden.
    private var replayPassage: some View {
        Button(action: steps.replay) {
            Label("Replay", systemImage: "gobackward").frame(maxWidth: .infinity)
        }
        .disabled(!steps.canReplay)
        .help("Replay the active paragraph with two seconds of context (Option-Command-R)")
    }

    private func step(_ title: LocalizedStringKey, systemImage: String, by offset: Int)
        -> some View
    {
        Button {
            steps.step(by: offset)
        } label: {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
        .disabled(!steps.canStep)
        .help(
            offset < 0
                ? "Play the previous paragraph (Option-Command-Up Arrow)"
                : "Play the next paragraph (Option-Command-Down Arrow)"
        )
        .accessibilityLabel(offset < 0 ? "Play the previous paragraph" : "Play the next paragraph")
    }
}

/// The inspector's button, at the trailing edge of the toolbar above it, the
/// mirror of the library's button at the leading edge. On macOS 26 a toolbar
/// item sits on glass, while the library's button, on the library's own glass,
/// has none, so this one leaves its glass out to match. Branched here rather
/// than inside the toolbar, where an availability check needs macOS 14.5.
struct InspectorToggle: ViewModifier {
    @Binding var isShown: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem { button }.sharedBackgroundVisibility(.hidden)
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
