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
    /// The tallest the picture may be.
    let maxHeight: CGFloat
    /// Small beside the player bar, when the window leaves the text too
    /// little room for the picture above it.
    let isThumbnail: Bool
    @AppStorage(EntryVideo.shownKey) private var isShown = true
    @State private var width: CGFloat = 0
    @State private var isHovered = false

    static let shownKey = "showsVideo"
    /// Below this, the picture above the player bar becomes a thumbnail.
    static let smallest: CGFloat = 100
    /// As tall as the player card beside it.
    static let thumbnailHeight: CGFloat = 102

    var body: some View {
        // Floating, the picture leaves the page to the text.
        if isShown, !model.video.isInPictureInPicture {
            if isThumbnail {
                shown
                    .frame(width: maxHeight * picture.width / picture.height, height: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                // Sized from the width, since the transcript takes every
                // point of height it is offered.
                shown
                    .frame(width: shownWidth, height: shownWidth * picture.height / picture.width)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                        if isHovered { controls }
                    }
                    .onHover { isHovered = $0 }
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        width = $0
                    }
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

    /// Over the picture while the pointer is on it, as other players do.
    private var controls: some View {
        HStack(spacing: 0) {
            control("pip.enter", "Picture in Picture", action: floatPicture)
            control("arrow.up.left.and.arrow.down.right", "Enter Full Screen", action: fillScreen)
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .environment(\.colorScheme, .dark)
        .padding(8)
    }

    private func control(
        _ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The whole width, unless the picture would then be taller than allowed.
    private var shownWidth: CGFloat {
        max(0, min(width, maxHeight * picture.width / picture.height))
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

/// Shows or hides the picture, beside the player card's title, or brings it
/// back from Picture in Picture.
struct VideoToggle: View {
    let video: VideoPresentation
    @AppStorage(EntryVideo.shownKey) private var isShown = true

    var body: some View {
        if video.isInPictureInPicture {
            Button(action: video.stopPictureInPicture) {
                Image(systemName: "pip.exit").frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .iconControl()
            .accessibilityLabel("Return Video to the Page")
            .help("Show the video beside the transcript again")
        } else {
            toggle
        }
    }

    private var toggle: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: isShown ? "video.slash" : "video")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .iconControl()
        .accessibilityLabel(isShown ? "Hide Video" : "Show Video")
        .help(isShown ? "Keep the sound only" : "Show the video")
    }
}

extension Entry {
    /// Whether the recording is a video file, by its name: the page shows its
    /// picture beside the text sooner, and the queue shows a film.
    var isVideo: Bool {
        UTType(filenameExtension: recording.pathExtension)?.conforms(to: .movie) == true
    }
}
