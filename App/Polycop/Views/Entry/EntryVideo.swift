// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The picture of a video recording, which the reader can hide to keep the
/// sound alone. Only these two views read that setting, and only a video has
/// them: a view that reads a setting is drawn again at each correction handed
/// over, which the player card of every transcript should not be.
struct EntryVideo: View {
    let model: AppModel
    let id: Entry.ID
    let source: URL
    let picture: CGSize
    /// Where the reader left off, played from when nothing is open yet.
    let resume: TimeInterval
    @AppStorage(EntryVideo.shownKey) private var isShown = true
    @State private var width: CGFloat = 0

    static let shownKey = "showsVideo"
    /// Tall enough for an upright phone video to leave the inspector room.
    static let tallest: CGFloat = 480

    var body: some View {
        // Floating, the picture leaves the inspector to the controls.
        if isShown, !model.video.isInPictureInPicture {
            // Sized from the inspector's width.
            shown
                .frame(width: shownWidth, height: shownWidth * picture.height / picture.width)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    width = $0
                }
        }
    }

    private var shown: some View {
        VideoView(player: shownPlayer, toggle: togglePlayback, fillScreen: fillScreen)
            .contextMenu {
                Button("Copy Frame", action: copyFrame)
                Divider()
                Button("Picture in Picture", action: floatPicture)
                Button("Enter Full Screen", action: fillScreen)
            }
            .accessibilityAction(named: "Picture in Picture", floatPicture)
            .accessibilityAction(named: "Enter Full Screen", fillScreen)
    }

    /// The whole width, unless the picture would then be taller than allowed.
    private var shownWidth: CGFloat {
        max(0, min(width, Self.tallest * picture.width / picture.height))
    }

    /// The player while it holds this recording; another one's picture, or
    /// none, leaves the frame black.
    private var shownPlayer: AVPlayer? {
        model.player.recording == source ? model.player.player : nil
    }

    private func togglePlayback() {
        if shownPlayer != nil {
            model.player.toggle()
        } else {
            model.replay(id, from: resume, leadIn: 0)
        }
    }

    private func floatPicture() {
        Task { await model.video.startPictureInPicture() }
    }

    private func fillScreen() {
        model.video.fillScreen { FullScreenVideo.window(for: model) }
    }

    /// The frame on screen, to paste a slide elsewhere.
    private func copyFrame() {
        let time = shownPlayer?.currentTime().seconds ?? resume
        Task {
            do {
                let frame = try await Player.frame(of: source, at: time)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: frame, size: .zero)])
            } catch {
                model.report(error)
            }
        }
    }
}

/// The video's buttons, always in sight in its section's heading: Picture in
/// Picture or its return, full screen, and the sound alone.
struct VideoControls: View {
    let model: AppModel
    @AppStorage(EntryVideo.shownKey) private var isShown = true

    var body: some View {
        HStack(spacing: 8) {
            if model.video.isInPictureInPicture {
                control(
                    "pip.exit", "Return Video from Picture in Picture",
                    help: "Show the video beside the transcript again"
                ) {
                    model.video.stopPictureInPicture()
                }
            } else {
                control(
                    "pip.enter", "Picture in Picture", help: "Float the video above other windows"
                ) {
                    Task { await model.video.startPictureInPicture() }
                }
            }
            control(
                "arrow.up.left.and.arrow.down.right", "Enter Full Screen",
                help: "Fill the screen with the video (double-click it)"
            ) {
                model.video.fillScreen { FullScreenVideo.window(for: model) }
            }
            control(
                isShown ? "video.slash" : "video", isShown ? "Hide Video" : "Show Video",
                help: isShown ? "Keep the sound only" : "Show the video"
            ) {
                isShown.toggle()
            }
        }
    }

    private func control(
        _ symbol: String, _ label: LocalizedStringKey, help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .iconControl()
        .accessibilityLabel(label)
        .help(help)
    }
}

extension Entry {
    /// Whether the recording is a video file, by its name: the page shows its
    /// picture beside the text sooner, and the queue shows a film.
    var isVideo: Bool {
        UTType(filenameExtension: recording.pathExtension)?.conforms(to: .movie) == true
    }
}
