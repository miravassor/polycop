// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The video's section of the inspector, which folds to keep the sound alone.
/// Only this view reads that setting, and only a video has it: a view that
/// reads a setting is drawn again at each correction handed over, which the
/// inspector of every transcript should not be.
struct VideoSection: View {
    let model: AppModel
    let id: Entry.ID
    let source: URL
    let picture: CGSize
    /// Where the reader left off, played from when nothing is open yet.
    let resume: TimeInterval
    @AppStorage("showsVideo") private var isShown = true

    var body: some View {
        Section("Video", isExpanded: $isShown) {
            EntryVideo(model: model, id: id, source: source, picture: picture, resume: resume)
        }
    }
}

/// The picture of a video recording, with Picture in Picture and full screen
/// on its corner while the pointer is over it, as on a video in Safari.
struct EntryVideo: View {
    let model: AppModel
    let id: Entry.ID
    let source: URL
    let picture: CGSize
    let resume: TimeInterval
    @State private var isHovering = false

    /// Tall enough for an upright phone video to leave the inspector room.
    static let tallest: CGFloat = 480

    var body: some View {
        // As wide as the inspector lets it be, never setting its width: a
        // measured width held the inspector from narrowing again.
        Group {
            if model.video.isInPictureInPicture { floating } else { shown }
        }
        .aspectRatio(picture.width / picture.height, contentMode: .fit)
        .frame(maxWidth: Self.tallest * picture.width / picture.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) { buttons }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .frame(maxWidth: .infinity)
    }

    /// Floating, the picture leaves a note in its place, and its button to
    /// bring it back.
    private var floating: some View {
        Label("Playing in Picture in Picture", systemImage: "pip")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
    }

    private var buttons: some View {
        let floats = model.video.isInPictureInPicture
        return HStack(spacing: 6) {
            Button {
                model.video.floatsPicture = !floats
            } label: {
                Label(
                    floats ? "Bring Back the Video" : "Picture in Picture",
                    systemImage: floats ? "pip.exit" : "pip.enter")
            }
            .help(
                floats
                    ? "Bring the video back beside the transcript"
                    : "Float the video above other windows")
            Button(action: fillScreen) {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fill the screen with the video (double-click it)")
        }
        .labelStyle(.iconOnly)
        .modifier(OnPicture())
        .padding(8)
        .opacity(isHovering || floats ? 1 : 0)
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

/// The buttons on the picture: glass on macOS 26, as the player's, and the
/// system's bordered circles before.
private struct OnPicture: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }
}

extension Entry {
    /// Whether the recording is a video file, by its name: the page shows its
    /// picture beside the text sooner, and the queue shows a film.
    var isVideo: Bool {
        UTType(filenameExtension: recording.pathExtension)?.conforms(to: .movie) == true
    }
}
