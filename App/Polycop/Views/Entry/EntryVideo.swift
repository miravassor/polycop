// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The video's section of the inspector, above its form rather than in it: a
/// form keeps its margins around a row whatever the row asks, and the picture
/// should take the width. It stays in view while the settings scroll.
struct VideoSection: View {
    let model: AppModel
    let id: Entry.ID
    let source: URL
    let picture: CGSize
    /// Where the reader left off, played from when nothing is open yet.
    let resume: TimeInterval

    /// The most height the picture may take.
    let tallest: CGFloat?

    // What a grouped form draws, measured on macOS 26, since none of it can be
    // asked: how far in it sets its sections, and the rows in them; the top of
    // its first title; the gap under a title. The picture lines up with the
    // sections' edges unless its height stops it first, the title with theirs.
    private static let formMargin: CGFloat = 10
    private static let firstTitleTop: CGFloat = 10
    private static let underTitle: CGFloat = 7

    var body: some View {
        VStack(spacing: Self.underTitle) {
            FoldTitle(.video, reading: model.reading)
                .padding(.horizontal, Self.formMargin)
            if !model.reading.foldedSections.contains(.video) {
                EntryVideo(
                    model: model, id: id, source: source, picture: picture, resume: resume,
                    tallest: tallest)
            }
        }
        .padding(.horizontal, Self.formMargin)
        .padding(.top, Self.firstTitleTop)
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
    let tallest: CGFloat?
    @State private var isHovering = false

    var body: some View {
        // As wide as the inspector lets it be, never setting its width: a
        // measured width held the inspector from narrowing again.
        Group {
            if model.video.isInPictureInPicture { floating } else { shown }
        }
        .aspectRatio(picture.width / picture.height, contentMode: .fit)
        .frame(maxWidth: tallest.map { $0 * picture.width / picture.height })
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
        model.video.startPictureInPicture()
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
