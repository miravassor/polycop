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
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var playing: Int?
    @State private var frames = RowFrames()

    var body: some View {
        VStack(spacing: 8) {
            if isComparing { headers }
            GeometryReader { viewport in
                ScrollViewReader { view in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(paragraphs.indices, id: \.self) { index in
                                row(index)
                                    .id(index)
                                    .onGeometryChange(for: CGRect.self) {
                                        $0.frame(in: .named("transcript"))
                                    } action: {
                                        frames.values[index] = $0
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
                    player: player, paragraph: paragraphs[index], isCurrent: playing == index,
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
            ParagraphText(
                player: player, isCurrent: playing == index,
                words: WordLayout.place(
                    index < words.count ? words[index] : [], in: paragraphs[index].text),
                editor: ParagraphEditor(
                    text: paragraphs[index].text,
                    original: written(at: index),
                    size: size,
                    isEditable: isEditable,
                    edit: { edit(index, $0) },
                    showsChanges: isComparing,
                    matches: matches.filter { $0.paragraph == index }.map(\.range),
                    currentMatch: currentMatch?.paragraph == index ? currentMatch?.range : nil,
                    activate: {
                        suspendFollowing()
                        activate(index)
                    },
                    showsUncertainWords: showsUncertainWords,
                    playFrom: { time in
                        activate(index)
                        play(time)
                    }
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
            if playing == index {
                RoundedRectangle(cornerRadius: 1).fill(.tint).frame(width: 2)
            }
        }
        .background(
            playing == index
                ? Color.accentColor.opacity(0.08)
                : focused == index ? Color.primary.opacity(0.04) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(active == index ? Color.primary.opacity(0.12) : .clear)
                .allowsHitTesting(false)
        }
    }

    private func written(at index: Int) -> String {
        index < original.count ? original[index].text : paragraphs[index].text
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
                Image(systemName: player.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 8, weight: .semibold))
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
}

nonisolated enum TranscriptNavigation {
    static func needsScroll(frame: CGRect?, height: CGFloat) -> Bool {
        guard let frame, height > 0 else { return true }
        // Long paragraphs only need their opening lines in view.
        return frame.minY < 0 || frame.minY + min(frame.height, 80) > height
    }

    /// The paragraph playing at `position`, with the half second of slack a jump takes.
    static func paragraph(playingAt position: TimeInterval, starts: [TimeInterval]) -> Int? {
        starts.lastIndex { $0 <= position + 0.5 }
    }

    /// The paragraph `offset` places away, kept inside the transcript. With no
    /// current paragraph, moving forward starts at the first one.
    static func paragraph(from current: Int?, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return offset >= 0 ? 0 : count - 1 }
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
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.wheeled(event)
                return event
            }
        }

        private func wheeled(_ event: NSEvent) {
            guard event.window === window, let scroll = enclosingScrollView,
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
