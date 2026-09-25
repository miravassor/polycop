// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The transcript, one paragraph per row, with the time it opens on beside it.
///
/// The time plays the recording from there and is bold while that paragraph is
/// being played. Once a job is over the text is editable in place, and the
/// engine's own words can be shown beside it.
struct TranscriptView: View {
    let paragraphs: [Transcript.Paragraph]
    /// Paragraphs where transcription resumed after a pause.
    let resumed: Set<Int>
    let player: Player
    let isEditable: Bool
    let play: (TimeInterval) -> Void
    let edit: (Int, String) -> Void
    /// The paragraph under the pointer, for the timeline below.
    let hover: (Int?) -> Void
    /// The transcript as the engine wrote it, to show what was corrected.
    let original: [Transcript.Paragraph]
    /// Shows that text beside the corrected one, in the same rows.
    let isComparing: Bool
    /// Scrolls to the paragraph being played.
    let isFollowing: Bool
    /// A paragraph to show at once, chosen on the timeline below.
    @Binding var jump: Int?
    /// The paragraph under the pointer, here or on the timeline.
    let focused: Int?
    let size: CGFloat
    let active: Int?
    let activate: (Int) -> Void
    let review: Set<Int>
    let toggleReview: (Int) -> Void
    let matches: [TranscriptSearch.Match]
    let currentMatch: TranscriptSearch.Match?

    /// The width of the column of times, shared with the headers above, so
    /// that each heading sits over its own text.
    private let timeColumnWidth: CGFloat = 68

    var body: some View {
        ScrollViewReader { view in
            ScrollView {
                LazyVStack(
                    alignment: .leading, spacing: 20,
                    pinnedViews: isComparing ? [.sectionHeaders] : []
                ) {
                    Section {
                        ForEach(paragraphs.indices, id: \.self) { index in
                            row(index).id(index)
                        }
                    } header: {
                        if isComparing { headers }
                    }
                }
            }
            // The player is read here rather than in the rows. Read there, a
            // position arriving four times a second measured every paragraph
            // again each time, and the scroll chased its own target.
            .overlay(alignment: .top) {
                Follow(player: player, starts: paragraphs.map(\.seconds), isEnabled: isFollowing) {
                    paragraph in
                    withAnimation(.easeOut(duration: 0.2)) {
                        view.scrollTo(paragraph, anchor: .center)
                    }
                }
            }
            .onChange(of: jump) { _, paragraph in
                guard let paragraph else { return }
                view.scrollTo(paragraph, anchor: .center)
                jump = nil
            }
        }
    }

    /// Which column is which, kept in view while the transcript scrolls: the
    /// two texts are alike enough that losing the heading loses the meaning.
    private var headers: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Color.clear.frame(width: timeColumnWidth, height: 1)
                Text("Original")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Your edit")
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            Divider()
        }
        .padding(.top, 2)
        .background(.background)
    }

    private func row(_ index: Int) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                ParagraphTime(
                    player: player,
                    paragraph: paragraphs[index],
                    until: index + 1 < paragraphs.count
                        ? paragraphs[index + 1].seconds : .greatestFiniteMagnitude,
                    play: {
                        activate(index)
                        play(paragraphs[index].seconds)
                    },
                    hover: { hover($0 ? index : nil) }
                )
                .frame(width: timeColumnWidth, alignment: .leading)
                Button {
                    activate(index)
                    toggleReview(index)
                } label: {
                    Image(systemName: review.contains(index) ? "flag.fill" : "flag")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(review.contains(index) ? Color.accentColor : Color.secondary)
                .disabled(!isEditable)
                .accessibilityLabel(
                    review.contains(index)
                        ? "Mark paragraph as reviewed" : "Mark paragraph for review"
                )
                .help(review.contains(index) ? "Remove review flag" : "Review this passage later")
                if resumed.contains(index) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Transcription resumed here after a pause")
                        .help("Words near this point can be missing or repeated.")
                }
            }
            .frame(width: timeColumnWidth, alignment: .leading)
            if isComparing {
                ParagraphEditor(
                    text: written(at: index), original: paragraphs[index].text,
                    size: size, isEditable: false, isRemoved: true, edit: { _ in }
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Original paragraph \(index + 1)")
            }
            ParagraphEditor(
                text: paragraphs[index].text,
                original: written(at: index),
                size: size,
                isEditable: isEditable,
                edit: { edit(index, $0) },
                showsChanges: isComparing,
                matches: matches.filter { $0.paragraph == index }.map(\.range),
                currentMatch: currentMatch?.paragraph == index ? currentMatch?.range : nil,
                activate: { activate(index) }
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
            if active == index {
                RoundedRectangle(cornerRadius: 1).fill(.tint).frame(width: 2)
            }
        }
        .background(
            focused == index ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func written(at index: Int) -> String {
        index < original.count ? original[index].text : paragraphs[index].text
    }
}

/// The time a paragraph opens on: a button that plays from there, bold while
/// that paragraph is the one being heard.
private struct ParagraphTime: View {
    let player: Player
    let paragraph: Transcript.Paragraph
    /// Where the next paragraph opens, which is where this one stops playing.
    let until: TimeInterval
    let play: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        Button(paragraph.time, action: play)
            .buttonStyle(.plain)
            .font(.callout.monospacedDigit())
            .fontWeight(isPlaying ? .bold : .regular)
            .foregroundStyle(.tint)
            .accessibilityLabel("Play from \(paragraph.time)")
            .help("Play from here")
            .onHover(perform: hover)
    }

    /// Half a second of slack, as the jump from a paragraph takes.
    private var isPlaying: Bool {
        guard player.isOpen else { return false }
        let reached = player.position + 0.5
        return reached >= paragraph.seconds && reached < until
    }
}

/// Scrolls to the paragraph being played, and nothing else. It draws nothing:
/// its only purpose is to read the player's position away from the rows.
private struct Follow: View {
    let player: Player
    let starts: [TimeInterval]
    let isEnabled: Bool
    let scroll: (Int) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: playing) { _, paragraph in
                guard isEnabled, let paragraph else { return }
                scroll(paragraph)
            }
            .onChange(of: isEnabled) { _, on in
                guard on, let paragraph = playing else { return }
                scroll(paragraph)
            }
    }

    private var playing: Int? {
        guard player.isOpen else { return nil }
        return starts.lastIndex { $0 <= player.position + 0.5 }
    }
}
