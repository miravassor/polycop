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

/// The picture of a video recording, with the transport at its centre and
/// Picture in Picture and full screen on its corner while the pointer is over it.
struct EntryVideo: View {
    let model: AppModel
    let id: Entry.ID
    let source: URL
    let picture: CGSize
    let resume: TimeInterval
    let tallest: CGFloat?
    @State private var pointer = PointerRest()
    @State private var shownWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    private var showsControls: Bool {
        VideoTransport.shows(
            isHovering: pointer.isHovering, isOverControl: pointer.isOverControl,
            isPointerResting: pointer.isResting, isPlaying: model.player.isPlaying)
    }

    var body: some View {
        // As wide as the inspector lets it be, never setting its width: a
        // measured width held the inspector from narrowing again.
        Group {
            if model.video.isInPictureInPicture { floating } else { shown }
        }
        .aspectRatio(picture.width / picture.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { transport }
        .overlay(alignment: .bottomTrailing) { buttons }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            shownWidth = $0
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: pointer.moved()
            case .ended: pointer.left()
            }
        }
        .animation(reducesMotion ? nil : .easeOut(duration: 0.15), value: showsControls)
        // After the corners and the buttons: a frame takes all the width it is
        // offered up to its maximum, wider than a picture its height holds back.
        .frame(maxWidth: tallest.map { $0 * picture.width / picture.height })
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

    private var transport: some View {
        let isShown = showsControls && !model.video.isInPictureInPicture
        return VideoTransport(
            player: model.player, diameter: VideoTransport.diameter(forWidth: shownWidth),
            canSkip: shownPlayer != nil, overSkip: { pointer.isOverControl = $0 }
        )
        .opacity(isShown ? 1 : 0)
        // Hidden, a click here is one on the picture, and Tab passes over them.
        .allowsHitTesting(isShown)
        .disabled(!isShown)
        .accessibilityHidden(!isShown)
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
        .onHover { pointer.isOverControl = $0 }
        .padding(8)
        .opacity(showsControls || floats ? 1 : 0)
        .allowsHitTesting(showsControls || floats)
    }

    private var shown: some View {
        VideoView(player: shownPlayer, toggle: togglePlayback, fillScreen: fillScreen)
            .contextMenu {
                Button("Copy Frame", action: copyFrame)
                Divider()
                Button("Picture in Picture", action: floatPicture)
                Button("Enter Full Screen", action: fillScreen)
            }
            // The controls on it show only under the pointer.
            .accessibilityAction(named: model.player.isPlaying ? "Pause" : "Play", togglePlayback)
            .accessibilityAction(named: "Back five seconds") { model.player.skip(by: -5) }
            .accessibilityAction(named: "Forward five seconds") { model.player.skip(by: 5) }
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

/// Whether the pointer is over the picture and has rested there: one owner for
/// the wait, restarted at each move without redrawing the picture.
@Observable
final class PointerRest {
    private(set) var isHovering = false
    private(set) var isResting = false
    /// Over a button the reader may press next, which keeps the controls.
    var isOverControl = false
    @ObservationIgnored private var wait: Task<Void, Never>?

    func moved() {
        if !isHovering { isHovering = true }
        if isResting { isResting = false }
        wait?.cancel()
        wait = Task { [weak self] in
            guard (try? await Task.sleep(for: VideoTransport.restsAfter)) != nil else { return }
            self?.isResting = true
        }
    }

    /// Clears the button too, whose own exit a window taken full screen may never send.
    func left() {
        wait?.cancel()
        isHovering = false
        isResting = false
        isOverControl = false
    }
}

/// Five seconds back, play or pause and five seconds on, in the player's words
/// and symbols, sized with the picture rather than by a text style, so that
/// they stay in proportion with it. The skips are buttons; play or pause is
/// drawn alike, but a click there is the picture's own, which also takes the
/// double click that fills the screen.
struct VideoTransport: View {
    let player: Player
    /// Of the skips; play or pause is larger.
    let diameter: CGFloat
    /// Whether the picture is the recording the player holds.
    let canSkip: Bool
    let overSkip: (Bool) -> Void

    /// How long the pointer rests before the controls leave a playing picture.
    static let restsAfter = Duration.seconds(2)

    // The two rules apart from the view, so that a test can check them.

    /// While the pointer is over the picture, until it has rested on a picture
    /// playing, other than on a button it may press next. Paused, the controls
    /// are what the reader came for.
    static func shows(
        isHovering: Bool, isOverControl: Bool, isPointerResting: Bool, isPlaying: Bool
    ) -> Bool {
        isHovering && (isOverControl || !isPointerResting || !isPlaying)
    }

    /// A tenth of the picture, within what can be pressed and what still looks
    /// like a control. The inspector's widths give 32 to 44; an upright picture less.
    static func diameter(forWidth width: CGFloat) -> CGFloat {
        min(max(width * 0.1, 26), 44)
    }

    var body: some View {
        HStack(spacing: diameter * 0.4) {
            skip(by: -5)
            symbol(
                player.isPlaying ? "Pause" : "Play",
                player.isPlaying ? "pause.fill" : "play.fill", size: diameter * 1.45
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            skip(by: 5)
        }
        .modifier(OnPicture())
    }

    private func skip(by seconds: TimeInterval) -> some View {
        let name: LocalizedStringKey = seconds < 0 ? "Back five seconds" : "Forward five seconds"
        return symbol(name, seconds < 0 ? "gobackward.5" : "goforward.5", size: diameter) {
            player.skip(by: seconds)
        }
        .disabled(!canSkip || player.isPreparing)
        .help(name)
        .onHover(perform: overSkip)
    }

    private func symbol(
        _ name: LocalizedStringKey, _ symbol: String, size: CGFloat,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            Label {
                Text(name)
            } icon: {
                Image(systemName: symbol).resizable().scaledToFit()
            }
            .labelStyle(.iconOnly)
            .padding(size * 0.25)
            .frame(width: size, height: size)
        }
    }
}

#Preview("On the picture") {
    VideoTransport(player: Player(), diameter: 36, canSkip: true, overSkip: { _ in })
        .padding(Spacing.sheet)
        .background(.gray)
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
