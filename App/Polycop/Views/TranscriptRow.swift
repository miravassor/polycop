// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One paragraph of the transcript. Compared by what it shows, not by its
/// actions, so that typing redraws the paragraph being typed in rather than
/// every one on screen. The page is rebuilt for each transcript, so the
/// actions of a row that is not redrawn still belong to it.
struct TranscriptRow: View, Equatable {
    let index: Int
    let paragraph: Transcript.Paragraph
    /// The paragraph as the engine wrote it.
    let written: String
    let player: Player
    let isEditable: Bool
    let isComparing: Bool
    let size: CGFloat
    let isPlaying: Bool
    let isFocused: Bool
    let isActive: Bool
    let isFlagged: Bool
    let isResumed: Bool
    let matches: [NSRange]
    let currentMatch: NSRange?
    let words: [Segment.Word]
    let showsUncertainWords: Bool
    let timeColumnWidth: CGFloat
    let play: (TimeInterval) -> Void
    let edit: (Int, String) -> Void
    let typing: () -> Void
    let hover: (Int?) -> Void
    let activate: (Int) -> Void
    let suspendFollowing: () -> Void
    let toggleReview: (Int) -> Void

    static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.index == rhs.index && lhs.paragraph == rhs.paragraph && lhs.written == rhs.written
            && lhs.player === rhs.player && lhs.isEditable == rhs.isEditable
            && lhs.isComparing == rhs.isComparing && lhs.size == rhs.size
            && lhs.isPlaying == rhs.isPlaying && lhs.isFocused == rhs.isFocused
            && lhs.isActive == rhs.isActive && lhs.isFlagged == rhs.isFlagged
            && lhs.isResumed == rhs.isResumed && lhs.matches == rhs.matches
            && lhs.currentMatch == rhs.currentMatch && lhs.words == rhs.words
            && lhs.showsUncertainWords == rhs.showsUncertainWords
            && lhs.timeColumnWidth == rhs.timeColumnWidth
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                ParagraphTime(
                    player: player, paragraph: paragraph, isCurrent: isPlaying,
                    play: {
                        activate(index)
                        play(paragraph.seconds)
                    },
                    hover: { hover($0 ? index : nil) }
                )
                .frame(width: timeColumnWidth, alignment: .leading)
                Button {
                    activate(index)
                    toggleReview(index)
                } label: {
                    Image(systemName: isFlagged ? "flag.fill" : "flag")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isFlagged ? Color.accentColor : Color.secondary)
                .disabled(!isEditable)
                // One label, with the flag as its state, as for any toggle.
                .accessibilityLabel("Flag paragraph \(index + 1) for review")
                .accessibilityAddTraits(isFlagged ? .isSelected : [])
                .help(isFlagged ? "Remove review flag" : "Review this passage later")
                if isResumed {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Transcription resumed here after a pause")
                        .help("Words near this point can be missing or repeated.")
                }
            }
            .frame(width: timeColumnWidth, alignment: .leading)
            if isComparing {
                ParagraphEditor(
                    text: written, original: paragraph.text,
                    size: size, isEditable: false, isRemoved: true, edit: { _ in }
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Original paragraph \(index + 1)")
            }
            ParagraphText(
                player: player, isCurrent: isPlaying,
                words: WordLayout.place(words, in: paragraph.text),
                editor: ParagraphEditor(
                    text: paragraph.text,
                    original: written,
                    size: size,
                    isEditable: isEditable,
                    edit: { edit(index, $0) },
                    showsChanges: isComparing,
                    matches: matches,
                    currentMatch: currentMatch,
                    activate: {
                        suspendFollowing()
                        activate(index)
                    },
                    timedStart: words.isEmpty ? nil : paragraph.seconds,
                    showsUncertainWords: showsUncertainWords,
                    playFrom: { time in
                        activate(index)
                        play(time)
                    },
                    typing: typing
                )
            )
            .padding(.horizontal, isComparing ? 8 : 0)
            .padding(.vertical, isComparing ? 4 : 0)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityLabel("Paragraph \(index + 1)")
            .accessibilityHint("Corrections are stored automatically.")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            if isPlaying {
                RoundedRectangle(cornerRadius: 1).fill(.tint).frame(width: 2)
            }
        }
        .background(
            isPlaying
                ? Color.accentColor.opacity(0.08)
                : isFocused ? Color.primary.opacity(0.04) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? Color.primary.opacity(0.12) : .clear)
                .allowsHitTesting(false)
        }
    }
}

/// A paragraph's editor, which reads the player's position only while its
/// paragraph is playing, so the other rows are not redrawn four times a second.
private struct ParagraphText: View {
    let player: Player
    let isCurrent: Bool
    let words: [WordLayout.Placed]
    let editor: ParagraphEditor
    @AppStorage(Player.cursorFollowsPlaybackKey) private var movesCursor = false

    var body: some View {
        var editor = editor
        editor.words = words
        editor.playingWord = isCurrent ? WordLayout.playing(words, at: player.position) : nil
        editor.movesCursor = isCurrent && player.isPlaying && movesCursor
        return editor
    }
}

/// The time a paragraph opens on: a button that plays from there, bold while
/// that paragraph is the one being heard.
private struct ParagraphTime: View {
    let player: Player
    let paragraph: Transcript.Paragraph
    let isCurrent: Bool
    let play: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 4) {
                // Read only in the current row, so play and pause redraw that row alone.
                Image(systemName: isCurrent && player.isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption2.weight(.semibold))
                    .imageScale(.small)
                    .frame(width: 8)
                    .opacity(isCurrent ? 1 : 0)
                    .accessibilityHidden(true)
                Text(paragraph.time)
            }
        }
        .buttonStyle(.plain)
        .font(.callout.monospacedDigit())
        .fontWeight(isCurrent ? .bold : .regular)
        .foregroundStyle(.tint)
        .accessibilityLabel("Play from \(paragraph.time)")
        .accessibilityValue(isCurrent ? (player.isPlaying ? "Playing" : "Paused") : "")
        .help("Play from here")
        .onHover(perform: hover)
    }
}
