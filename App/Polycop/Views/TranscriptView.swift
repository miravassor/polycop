// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
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
    /// Called at each key typed in a paragraph.
    let typing: () -> Void
    /// The paragraph under the pointer, for the timeline below.
    let hover: (Int?) -> Void
    /// The transcript as the engine wrote it, to show what was corrected.
    let original: [Transcript.Paragraph]
    /// Shows that text beside the corrected one, in the same rows.
    let isComparing: Bool
    /// Scrolls to the paragraph being played.
    let isFollowing: Bool
    let suspendFollowing: () -> Void
    /// A paragraph to show at once, chosen on the timeline below.
    @Binding var jump: Int?
    /// The paragraph to open on, where the reader left the transcript.
    let start: Int?
    /// Told which paragraph is at the top of the page as the reader scrolls.
    let scrolled: (Int) -> Void
    /// The paragraph under the pointer, here or on the timeline.
    let focused: Int?
    let size: CGFloat
    let active: Int?
    let activate: (Int) -> Void
    let review: Set<Int>
    let toggleReview: (Int) -> Void
    let matches: [TranscriptSearch.Match]
    let currentMatch: TranscriptSearch.Match?
    /// The timed words of each paragraph, empty for an engine that times none.
    let words: [[Segment.Word]]
    let showsUncertainWords: Bool

    /// The width of the column of times, shared with the headers above, so
    /// that each heading sits over its own text.
    private let timeColumnWidth: CGFloat = 80
    private let rowSpacing: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var playing: Int?
    @State private var frames = RowFrames()

    var body: some View {
        VStack(spacing: 8) {
            if isComparing { headers }
            GeometryReader { viewport in
                ScrollViewReader { view in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: rowSpacing) {
                            ForEach(paragraphs.indices, id: \.self) { index in
                                row(index)
                                    .equatable()
                                    .id(index)
                                    .onGeometryChange(for: CGRect.self) {
                                        $0.frame(in: .named("transcript"))
                                    } action: {
                                        frames.values[index] = $0
                                        // Rows gone from the page keep their last
                                        // frame, so the top is the row that says so.
                                        if TranscriptNavigation.isAtTop($0, spacing: rowSpacing),
                                            frames.top != index
                                        {
                                            frames.top = index
                                            scrolled(index)
                                        }
                                    }
                                    .onDisappear { frames.values[index] = nil }
                            }
                        }
                        .background(ManualScroll(action: suspendFollowing))
                    }
                    .coordinateSpace(name: "transcript")
                    // Keep timer updates away from the paragraph layout.
                    .overlay(alignment: .top) {
                        Follow(
                            player: player, starts: paragraphs.map(\.seconds),
                            isEnabled: isFollowing, update: { playing = $0 }
                        ) { paragraph in
                            scroll(to: paragraph, in: view, height: viewport.size.height)
                        }
                    }
                    .onAppear {
                        if let start, paragraphs.indices.contains(start) {
                            view.scrollTo(start, anchor: .top)
                        }
                    }
                    .onChange(of: jump) { _, paragraph in
                        guard let paragraph else { return }
                        scroll(to: paragraph, in: view, height: viewport.size.height)
                        jump = nil
                    }
                }
            }
        }
    }

    private func scroll(to paragraph: Int, in view: ScrollViewProxy, height: CGFloat) {
        let frame = frames.values[paragraph]
        guard TranscriptNavigation.needsScroll(frame: frame, height: height) else { return }
        withAnimation(reducesMotion ? nil : .easeInOut(duration: 0.24)) {
            view.scrollTo(paragraph, anchor: .top)
        }
    }

    /// Which column is which, above the scrolling transcript: the two texts are
    /// alike enough that losing the heading loses the meaning.
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
    }

    private func row(_ index: Int) -> TranscriptRow {
        TranscriptRow(
            index: index, paragraph: paragraphs[index], written: written(at: index),
            player: player, isEditable: isEditable, isComparing: isComparing, size: size,
            isPlaying: playing == index, isFocused: focused == index, isActive: active == index,
            isReviewed: review.contains(index), isResumed: resumed.contains(index),
            matches: matches.filter { $0.paragraph == index }.map(\.range),
            currentMatch: currentMatch?.paragraph == index ? currentMatch?.range : nil,
            words: index < words.count ? words[index] : [],
            showsUncertainWords: showsUncertainWords, timeColumnWidth: timeColumnWidth,
            play: play, edit: edit, typing: typing, hover: hover, activate: activate,
            suspendFollowing: suspendFollowing, toggleReview: toggleReview)
    }

    private func written(at index: Int) -> String {
        index < original.count ? original[index].text : paragraphs[index].text
    }
}

/// Where each row on screen sits, read only when following jumps. A plain
/// class rather than state, so rows moving during a scroll redraw nothing.
private final class RowFrames {
    var values: [Int: CGRect] = [:]
    /// The paragraph at the top of the page, kept while rows come and go.
    var top: Int?
}
