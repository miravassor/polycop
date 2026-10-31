// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The player at the foot of a transcript, whether or not a file is open.
///
/// The length is known from the transcription, so the timeline exists before
/// anything plays and a point chosen on it opens the recording there. Each
/// paragraph is a mark, stronger under the pointer, so a passage can be found
/// by eye before it is heard.
struct PlayerBar: View, @MainActor Equatable {
    /// The bar's width at its narrowest, with its controls on one line.
    static let narrowest: CGFloat = 410

    @Bindable var player: Player
    /// The opening second of each paragraph.
    let marks: [TimeInterval]
    /// The paragraph whose time the pointer is over, if any.
    let highlighted: Int?
    /// The length the transcription measured, used until a file is open.
    let length: TimeInterval
    /// Where playback stood when the transcript was last left, until a file is open.
    let resume: TimeInterval
    /// Opens the recording at a point and plays from there.
    let play: (TimeInterval) -> Void
    /// The mark the pointer is over, so the text can show which paragraph it is.
    let hover: (Int?) -> Void
    /// A paragraph chosen on the timeline, to be shown in the text above.
    let jump: (Int) -> Void

    @State private var scrubbed: TimeInterval?
    @State private var width: CGFloat = 0

    /// Compared without its actions, which stay the same for a page: a
    /// correction handed over gives the page a new transcript, not the player
    /// anything new to draw, so its timeline is not laid out again. What it
    /// observes of the player still redraws it.
    static func == (lhs: PlayerBar, rhs: PlayerBar) -> Bool {
        lhs.player === rhs.player && lhs.marks == rhs.marks
            && lhs.highlighted == rhs.highlighted && lhs.length == rhs.length
            && lhs.resume == rhs.resume
    }

    private var duration: TimeInterval { player.duration > 0 ? player.duration : length }
    private var position: TimeInterval {
        scrubbed ?? (player.isOpen ? player.position : resume)
    }

    var body: some View {
        // As the Music player: the transport, the timeline between the time
        // played and the time left, then the speed, all centred on one line;
        // the timeline takes a line of its own when the column is narrow.
        // Its own width only changes as the window does.
        Group {
            if width >= Self.oneLine {
                HStack(spacing: 14) {
                    transport
                    timed
                    preparing
                    speed
                }
            } else {
                VStack(spacing: 2) {
                    HStack(spacing: 14) {
                        transport
                        preparing
                        Spacer()
                        speed
                    }
                    timed
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .modifier(PlayerSurface(isOneLine: width >= Self.oneLine))
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .background(SpaceToPlay(isEnabled: !player.isPreparing, action: playOrPause))
    }

    /// The timeline between the time played and the time left, on its line.
    private var timed: some View {
        HStack(spacing: 10) {
            time(Self.clock(position))
            timeline
            time("-\(Self.clock(max(0, duration - position)))")
        }
    }

    private func time(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    /// The width from which the player fits on one line.
    private static let oneLine: CGFloat = 500

    private var timeline: some View {
        Timeline(
            duration: duration, position: position, marks: marks, highlighted: highlighted,
            current: player.isOpen
                ? TranscriptNavigation.paragraph(playingAt: player.position, starts: marks)
                : nil,
            hover: hover, jump: jump,
            scrub: { scrubbed = $0 },
            reach: seek
        )
    }

    /// Five seconds back, play, five seconds forward, as plain symbols as in
    /// the Music player. Stop is in the Playback menu, as a transport keeps to
    /// what is pressed while listening.
    private var transport: some View {
        HStack(spacing: 14) {
            skip(by: -5)
            Button(action: playOrPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(player.isPreparing)
            .keyboardShortcut(.space, modifiers: [.command, .shift])
            .help("Play or pause (Space, or Shift-Command-Space while editing text)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            skip(by: 5)
        }
        .foregroundStyle(.primary)
    }

    private func skip(by seconds: TimeInterval) -> some View {
        Button {
            seek(min(duration, max(0, position + seconds)))
        } label: {
            Image(systemName: seconds < 0 ? "gobackward.5" : "goforward.5")
                .font(.title3)
                .frame(width: 24, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(player.isPreparing || duration <= 0)
        .help(seconds < 0 ? "Back five seconds" : "Forward five seconds")
        .accessibilityLabel(seconds < 0 ? "Back five seconds" : "Forward five seconds")
    }

    @ViewBuilder private var preparing: some View {
        if player.isPreparing {
            ProgressView().controlSize(.small)
            Text("Preparing playback").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func playOrPause() {
        if player.isOpen {
            player.toggle()
        } else {
            play(position)
        }
    }

    private func seek(_ time: TimeInterval) {
        scrubbed = nil
        if player.isOpen {
            player.seek(to: time)
        } else {
            play(time)
        }
    }

    private var speed: some View {
        Menu {
            Picker(
                "Playing speed",
                selection: $player.speed
            ) {
                ForEach(Player.speeds, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(label(player.speed))
                .font(.callout.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playing speed")
        .accessibilityLabel("Playing speed")
        .accessibilityValue(label(player.speed))
    }

    private func label(_ speed: Float) -> String {
        "\(Double(speed).formatted(.number.precision(.fractionLength(0...2))))×"
    }

    /// Bounded, so that a position read from a damaged record cannot trap in
    /// the conversion.
    static func clock(_ time: TimeInterval) -> String {
        Transcript.clock(Int(min(max(0, time), AudioDecoder.longestRecording + 60) * 1000))
    }
}

/// Where the recording is, where its paragraphs open, and where a click lands.
private struct Timeline: View {
    let duration: TimeInterval
    let position: TimeInterval
    let marks: [TimeInterval]
    let highlighted: Int?
    let current: Int?
    let hover: (Int?) -> Void
    let jump: (Int) -> Void
    let scrub: (TimeInterval) -> Void
    let reach: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = TimelineScale(width: width, duration: duration)
            let played = scale.offset(for: position)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: scale.trackWidth, height: 4)
                    .offset(x: scale.inset)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(0, played - scale.inset), height: 4)
                    .offset(x: scale.inset)
                ForEach(marks.indices, id: \.self) { index in
                    let strong = index == highlighted || index == current
                    Rectangle()
                        .fill(
                            index == current
                                ? AnyShapeStyle(.tint)
                                : index == highlighted
                                    ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                        )
                        .frame(width: strong ? 2 : 1, height: strong ? 18 : 12)
                        .position(x: scale.offset(for: marks[index]), y: 14)
                }
                Circle()
                    .fill(.tint)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .position(x: played, y: 14)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { scrub(time(at: $0.location.x, across: width)) }
                    .onEnded { reach(time(at: $0.location.x, across: width)) }
            )
            // A double click asks to read that passage, not only to hear it.
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { tap in
                        if let paragraph = paragraph(at: tap.location.x, across: width) {
                            jump(paragraph)
                        }
                    }
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): hover(mark(near: point.x, across: width))
                case .ended: hover(nil)
                }
            }
            .allowsHitTesting(duration > 0)
            .accessibilityElement()
            .accessibilityLabel("Timeline")
            .accessibilityValue(PlayerBar.clock(position))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: reach(min(duration, position + 5))
                case .decrement: reach(max(0, position - 5))
                @unknown default: break
                }
            }
        }
        .frame(height: 28)
    }

    /// The paragraph whose mark the pointer is on, within a few points of it.
    private func mark(near x: CGFloat, across width: CGFloat) -> Int? {
        guard width > 0, duration > 0 else { return nil }
        let scale = TimelineScale(width: width, duration: duration)
        let nearest = marks.indices.min {
            abs(scale.offset(for: marks[$0]) - x) < abs(scale.offset(for: marks[$1]) - x)
        }
        guard let nearest, abs(scale.offset(for: marks[nearest]) - x) <= 5 else { return nil }
        return nearest
    }

    /// The paragraph a point of the timeline belongs to: the mark itself when
    /// the pointer is on one, otherwise the paragraph being spoken there.
    private func paragraph(at x: CGFloat, across width: CGFloat) -> Int? {
        if let exact = mark(near: x, across: width) { return exact }
        let moment = time(at: x, across: width)
        return marks.lastIndex { $0 <= moment } ?? (marks.isEmpty ? nil : 0)
    }

    private func time(at x: CGFloat, across width: CGFloat) -> TimeInterval {
        TimelineScale(width: width, duration: duration).time(at: x)
    }
}

/// Drawing and hit testing share the inset that keeps the thumb inside the track.
nonisolated struct TimelineScale {
    let width: CGFloat
    let duration: TimeInterval

    var inset: CGFloat { min(7, max(0, width) / 2) }
    var trackWidth: CGFloat { max(0, width - 2 * inset) }

    func offset(for time: TimeInterval) -> CGFloat {
        guard duration.isFinite, duration > 0, time.isFinite else { return inset }
        return inset + trackWidth * min(1, max(0, time / duration))
    }

    func time(at x: CGFloat) -> TimeInterval {
        guard trackWidth > 0, duration.isFinite, duration > 0, x.isFinite else { return 0 }
        return min(1, max(0, (x - inset) / trackWidth)) * duration
    }
}

/// The player's surface: glass on macOS 26, as Music's player, blurring the
/// text that scrolls under it; the system's material before. A capsule on one
/// line, a rounded rectangle on two.
private struct PlayerSurface: ViewModifier {
    let isOneLine: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: isOneLine ? 26 : 18)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
