// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The player at the foot of a transcript, whether or not a file is open.
///
/// The length is known from the transcription, so the timeline exists before
/// anything plays and a point chosen on it opens the recording there. It runs
/// across the bar, on a line of its own, so that a long lecture has room on it.
struct PlayerBar: View, @MainActor Equatable {
    /// The bar's width at its narrowest, which holds the line under the
    /// timeline with the times of a recording of hours and the widest speed.
    static let narrowest: CGFloat = 450
    /// Its distance from the window's foot, level with the foot of the
    /// library, which floats 8 points in on macOS 26.
    static let foot: CGFloat = 8

    @Bindable var player: Player
    /// The opening second of each paragraph.
    let marks: [TimeInterval]
    /// The paragraph under the pointer, in the text or on the timeline.
    let pointer: ParagraphPointer
    /// Whether the reader has scrolled away from what plays.
    let isFollowSuspended: Bool
    /// The length the transcription measured, used until a file is open.
    let length: TimeInterval
    /// Where playback stood when the transcript was last left, until a file is open.
    let resume: TimeInterval
    /// Opens the recording at a point and plays from there.
    let play: (TimeInterval) -> Void
    /// A paragraph chosen on the timeline, to be shown in the text above.
    let jump: (Int) -> Void
    /// Plays the paragraph before or after, as the Playback menu does.
    let step: (Int) -> Void
    /// Shows the paragraph playing and follows it again.
    let returnToPlayback: () -> Void

    @State private var scrubbed: TimeInterval?

    /// The height of the line under the timeline, and of its buttons.
    private static let row: CGFloat = 28
    /// More at the top, where the playhead rises above its line.
    private static let padding = EdgeInsets(top: 8, leading: 18, bottom: 6, trailing: 18)

    /// Compared without its actions, which stay the same for a page: a
    /// correction handed over gives the page a new transcript, not the player
    /// anything new to draw, so its timeline is not laid out again. What it
    /// observes of the player still redraws it.
    static func == (lhs: PlayerBar, rhs: PlayerBar) -> Bool {
        lhs.player === rhs.player && lhs.marks == rhs.marks
            && lhs.pointer === rhs.pointer && lhs.isFollowSuspended == rhs.isFollowSuspended
            && lhs.length == rhs.length
            && lhs.resume == rhs.resume
    }

    private var duration: TimeInterval { player.duration > 0 ? player.duration : length }
    private var position: TimeInterval {
        scrubbed ?? (player.isOpen ? player.position : resume)
    }

    var body: some View {
        // The timeline across the bar. Under it the time played at one
        // end and the time left at the other, and between them the transport
        // with the speed: the same at every width. The words of a recording
        // being prepared go where the bar is too narrow for them.
        VStack(spacing: 0) {
            timeline
            ViewThatFits(in: .horizontal) {
                controls(preparingInWords: true)
                controls(preparingInWords: false)
            }
        }
        .padding(Self.padding)
        .modifier(FloatingSurface(shape: Capsule()))
        .background(SpaceToPlay(isEnabled: !player.isPreparing, action: playOrPause))
    }

    /// The time played and the way back to playback on one side of the
    /// transport, the speed and the time left on the other. The sides share
    /// what room is left, which keeps Play at the centre of the bar.
    private func controls(preparingInWords: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                time(Self.clock(position, of: duration)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                // A recording being prepared has no playback to return to.
                if player.isPreparing {
                    preparing(inWords: preparingInWords)
                } else {
                    returning
                }
            }
            .frame(maxWidth: .infinity)
            transport
            HStack(spacing: 10) {
                speed
                Spacer(minLength: 0)
                // Unknown until the recording is decoded or opened.
                if duration > 0 {
                    time("-\(Self.clock(max(0, duration - position), of: duration))")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Lit once the reader has scrolled away from what plays, and dim while
    /// the page follows, as the arrow of a map is.
    private var returning: some View {
        Button(action: returnToPlayback) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.body)
                .frame(width: 26, height: Self.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isFollowSuspended ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .disabled(!isFollowSuspended)
        .help("Return to Playback (Option-Command-L)")
        .accessibilityLabel("Return to Playback")
    }

    /// The time played or the time left, alike but for their colour: the
    /// time played, in the label colour, is what says where we are.
    /// VoiceOver hears both from the timeline.
    private func time(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospacedDigit().weight(.medium))
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var timeline: some View {
        PlayerTimeline(
            duration: duration, position: position, marks: marks, pointer: pointer,
            jump: jump,
            scrub: { scrubbed = $0 },
            reach: seek
        )
    }

    /// Five seconds back, play, five seconds forward, as plain symbols as in
    /// the Music player, between the previous and the next paragraph, where
    /// Music has the previous and next song, each a size under the one it
    /// surrounds. Stop is in the Playback menu, as a transport keeps to what
    /// is pressed while listening.
    private var transport: some View {
        HStack(spacing: 4) {
            paragraph(by: -1)
            skip(by: -5)
            Button(action: playOrPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 32, height: Self.row)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(player.isPreparing)
            .keyboardShortcut(.space, modifiers: [.command, .shift])
            .help("Play or pause (Space, or Shift-Command-Space while editing text)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            skip(by: 5)
            paragraph(by: 1)
        }
        .foregroundStyle(.primary)
    }

    private func paragraph(by offset: Int) -> some View {
        Button {
            step(offset)
        } label: {
            Image(systemName: offset < 0 ? "backward.end.fill" : "forward.end.fill")
                .font(.body)
                .frame(width: 26, height: Self.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(player.isPreparing || marks.isEmpty)
        .help(
            offset < 0
                ? "Start of this paragraph, or the one before in its first seconds (Option-Command-Up Arrow)"
                : "Next paragraph (Option-Command-Down Arrow)"
        )
        .accessibilityLabel(offset < 0 ? "Previous paragraph" : "Next paragraph")
    }

    private func skip(by seconds: TimeInterval) -> some View {
        Button {
            seek(min(duration, max(0, position + seconds)))
        } label: {
            Image(systemName: seconds < 0 ? "gobackward.5" : "goforward.5")
                .font(.title3)
                .frame(width: 26, height: Self.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(player.isPreparing || duration <= 0)
        .help(seconds < 0 ? "Back five seconds" : "Forward five seconds")
        .accessibilityLabel(seconds < 0 ? "Back five seconds" : "Forward five seconds")
    }

    @ViewBuilder private func preparing(inWords: Bool) -> some View {
        if player.isPreparing {
            if inWords {
                Text("Preparing playback").font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: Self.row)
                .help("Preparing playback")
                .accessibilityLabel("Preparing playback")
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

    /// A time of a recording, with the hours only where it has any, so that
    /// its two times read alike. Bounded, so that a position read from a
    /// damaged record cannot trap in the conversion.
    nonisolated static func clock(_ time: TimeInterval, of length: TimeInterval) -> String {
        let seconds = Int(min(max(0, time), AudioDecoder.longestRecording + 60))
        return Transcript.shortClock(seconds, withHours: max(time, length) >= 3600)
    }
}
