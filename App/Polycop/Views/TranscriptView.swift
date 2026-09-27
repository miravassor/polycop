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

/// One paragraph of the transcript. Compared by what it shows, not by its
/// actions, so that typing redraws the paragraph being typed in rather than
/// every one on screen. The page is rebuilt for each transcript, so the
/// actions of a row that is not redrawn still belong to it.
private struct TranscriptRow: View, Equatable {
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
    let isReviewed: Bool
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
            && lhs.isActive == rhs.isActive && lhs.isReviewed == rhs.isReviewed
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
                    Image(systemName: isReviewed ? "flag.fill" : "flag")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isReviewed ? Color.accentColor : Color.secondary)
                .disabled(!isEditable)
                .accessibilityLabel(
                    isReviewed
                        ? "Mark paragraph as reviewed" : "Mark paragraph for review"
                )
                .help(isReviewed ? "Remove review flag" : "Review this passage later")
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

    var body: some View {
        var editor = editor
        editor.words = words
        editor.playingWord = isCurrent ? WordLayout.playing(words, at: player.position) : nil
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

/// Reads playback away from the rows so only a change of paragraph updates them.
private struct Follow: View {
    let player: Player
    let starts: [TimeInterval]
    let isEnabled: Bool
    let update: (Int?) -> Void
    let scroll: (Int) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: playing, initial: true) { _, paragraph in
                update(paragraph)
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
        return TranscriptNavigation.paragraph(playingAt: player.position, starts: starts)
    }
}

/// Where each row on screen sits, read only when following jumps. A plain
/// class rather than state, so rows moving during a scroll redraw nothing.
private final class RowFrames {
    var values: [Int: CGRect] = [:]
    /// The paragraph at the top of the page, kept while rows come and go.
    var top: Int?
}

/// Which paragraph plays, and when following needs to scroll to it.
nonisolated enum TranscriptNavigation {
    static func needsScroll(frame: CGRect?, height: CGFloat) -> Bool {
        guard let frame, height > 0 else { return true }
        // Long paragraphs only need their opening lines in view.
        return frame.minY < 0 || frame.minY + min(frame.height, 80) > height
    }

    /// Whether a row is the one at the top of the page: across its top edge, or
    /// just below it, within the spacing before the next row.
    static func isAtTop(_ frame: CGRect, spacing: CGFloat) -> Bool {
        frame.maxY > 0 && frame.minY <= spacing
    }

    /// The paragraph playing at `position`, with the half second of slack a jump takes.
    static func paragraph(playingAt position: TimeInterval, starts: [TimeInterval]) -> Int? {
        starts.lastIndex { $0 <= position + 0.5 }
    }

    /// The paragraph `offset` places away, kept inside the transcript. With no
    /// current paragraph, as before the first one, both directions start at
    /// the first one.
    static func paragraph(from current: Int?, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return min(max(0, current + offset), count - 1)
    }
}

/// Tells the reader's scrolling from the jumps of following. Wheel and
/// trackpad scrolls are seen as events, since a mouse wheel starts no live
/// scroll; dragging the scroller starts one.
struct ManualScroll: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Observer {
        Observer(action: action)
    }

    func updateNSView(_ view: Observer, context: Context) {
        view.action = action
    }

    static func dismantleNSView(_ view: Observer, coordinator: ()) {
        view.stopMonitoring()
    }

    final class Observer: NSView {
        var action: () -> Void
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrolled(_:)),
                name: NSScrollView.willStartLiveScrollNotification, object: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.wheeled(event)
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Fingers resting on the trackpad send events that move nothing.
        private func wheeled(_ event: NSEvent) {
            guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0,
                event.window === window, let scroll = enclosingScrollView,
                scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            else { return }
            action()
        }

        @objc private func scrolled(_ notification: Notification) {
            guard let scroll = notification.object as? NSScrollView,
                scroll === enclosingScrollView
            else { return }
            action()
        }
    }
}
