// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The player at the foot of a transcript, whether or not a file is open.
///
/// The length is known from the transcription, so the timeline exists before
/// anything plays and a point chosen on it opens the recording there. It runs
/// across the bar, on a line of its own, so that a long lecture has room on it.
struct PlayerBar: View, @MainActor Equatable {
    /// The bar's width at its narrowest, which holds the line under the timeline.
    static let narrowest: CGFloat = 410
    /// Its distance from the window's foot, level with the foot of the
    /// library, which floats 8 points in on macOS 26.
    static let foot: CGFloat = 8

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
    /// Plays the paragraph before or after, as the Playback menu does.
    let step: (Int) -> Void

    @State private var scrubbed: TimeInterval?

    /// The height of the line under the timeline, and of its buttons.
    private static let row: CGFloat = 30
    private static let padding = EdgeInsets(top: 4, leading: 18, bottom: 6, trailing: 18)

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
        // The timeline across the bar. Under it the time played, the one
        // number that moves, the transport centred, then the length and the
        // speed: the same at every width.
        VStack(spacing: 0) {
            timeline
            HStack(spacing: 10) {
                // The words go where the bar is too narrow for them; the
                // spinner stays.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        played
                        preparing(inWords: true)
                    }
                    HStack(spacing: 6) {
                        played
                        preparing(inWords: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                transport
                HStack(spacing: 10) {
                    // Unknown until the recording is decoded or opened.
                    if duration > 0 {
                        Text(Self.clock(duration, of: duration))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                    speed
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(Self.padding)
        .modifier(FloatingSurface(shape: Capsule()))
        .background(SpaceToPlay(isEnabled: !player.isPreparing, action: playOrPause))
    }

    /// The time played, larger than the length and in the label colour: it
    /// is what says where we are. VoiceOver hears both from the timeline.
    private var played: some View {
        Text(Self.clock(position, of: duration))
            .font(.body.monospacedDigit().weight(.medium))
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var timeline: some View {
        PlayerTimeline(
            duration: duration, position: position, marks: marks, highlighted: highlighted,
            hover: hover, jump: jump,
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
                ? "Previous paragraph (Option-Command-Up Arrow)"
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
            ProgressView()
                .controlSize(.small)
                .help("Preparing playback")
                .accessibilityLabel("Preparing playback")
            if inWords {
                Text("Preparing playback").font(.caption).foregroundStyle(.secondary).fixedSize()
            }
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
                .font(.body.monospacedDigit())
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
