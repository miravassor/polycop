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
    /// Plays the paragraph before or after, as the Playback menu does.
    let step: (Int) -> Void

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
        // the timeline takes a line of its own when the column is narrow,
        // under the transport centred. Its own width only changes as the
        // window does.
        Group {
            if width >= Self.oneLine {
                HStack(spacing: 10) {
                    transport
                    timed
                    preparing
                    speed
                }
            } else {
                VStack(spacing: 2) {
                    HStack(spacing: 10) {
                        HStack { preparing }.frame(maxWidth: .infinity, alignment: .leading)
                        transport
                        speed.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    timed
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .modifier(FloatingSurface(cornerRadius: width >= Self.oneLine ? 26 : 18))
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .background(SpaceToPlay(isEnabled: !player.isPreparing, action: playOrPause))
    }

    /// The timeline between the time played and the time left, on its line.
    private var timed: some View {
        HStack(spacing: 6) {
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
    private static let oneLine: CGFloat = 580

    private var timeline: some View {
        PlayerTimeline(
            duration: duration, position: position, marks: marks, highlighted: highlighted,
            current: player.isOpen
                ? TranscriptNavigation.paragraph(playingAt: player.position, starts: marks)
                : nil,
            rate: player.isPlaying ? Double(player.speed) : 0,
            hover: hover, jump: jump,
            scrub: { scrubbed = $0 },
            reach: seek
        )
    }

    /// Five seconds back, play, five seconds forward, as plain symbols as in
    /// the Music player, between the previous and the next paragraph, where
    /// Music has the previous and next song. Stop is in the Playback menu, as
    /// a transport keeps to what is pressed while listening.
    private var transport: some View {
        HStack(spacing: 4) {
            paragraph(by: -1)
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
                .frame(width: 24, height: 32)
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
            Text("Preparing playback").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
