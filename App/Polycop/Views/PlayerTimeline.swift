// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Where the recording is, and where a click lands: a thin line, played in
/// the accent colour up to a narrow upright playhead. The paragraphs show
/// around the pointer only, where one is about to be chosen, so that a lecture
/// of a hundred paragraphs keeps a plain line at rest.
struct PlayerTimeline: View {
    /// The height that takes clicks and holds the playhead at its tallest.
    static let height: CGFloat = 20

    let duration: TimeInterval
    let position: TimeInterval
    let marks: [TimeInterval]
    let highlighted: Int?
    let hover: (Int?) -> Void
    let jump: (Int) -> Void
    let scrub: (TimeInterval) -> Void
    let reach: (TimeInterval) -> Void
    /// Where the pointer is over the timeline, and where it drags the playhead.
    @State private var hovered: CGFloat?
    @State private var dragged: CGFloat?

    /// What the reader is doing with the timeline, which its sizes follow.
    private enum Stage { case resting, hovered, dragged }

    private var stage: Stage {
        dragged != nil ? .dragged : hovered != nil ? .hovered : .resting
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = TimelineScale(width: geometry.size.width, duration: duration)
            track(on: scale)
                .frame(height: Self.height)
                .animation(.default, value: stage)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            dragged = drag.location.x
                            scrub(scale.time(at: drag.location.x))
                        }
                        .onEnded { drag in
                            dragged = nil
                            reach(scale.time(at: drag.location.x))
                        }
                )
                // A double click asks to read that passage, not only to hear it.
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { tap in
                            if let paragraph = paragraph(at: tap.location.x, on: scale) {
                                jump(paragraph)
                            }
                        }
                )
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        hovered = point.x
                        hover(scale.mark(near: point.x, among: marks))
                    case .ended:
                        hovered = nil
                        hover(nil)
                    }
                }
                .allowsHitTesting(duration > 0)
                .accessibilityElement()
                .accessibilityLabel("Timeline")
                .accessibilityValue(PlayerBar.clock(position, of: duration))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: reach(min(duration, position + 5))
                    case .decrement: reach(max(0, position - 5))
                    @unknown default: break
                    }
                }
        }
        .frame(height: Self.height)
    }

    /// The line, its played part, the marks around the pointer and the playhead.
    private func track(on scale: TimelineScale) -> some View {
        let played = scale.offset(for: position)
        let line: CGFloat = stage == .resting ? 3 : 5
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(.quaternary)
                .frame(width: scale.trackWidth, height: line)
                .offset(x: scale.inset)
            Capsule()
                .fill(.tint)
                .frame(width: max(0, played - scale.inset), height: line)
                .offset(x: scale.inset)
            paragraphMarks(on: scale, clearOf: played)
            Capsule()
                .fill(.tint)
                .frame(
                    width: stage == .resting ? 3 : 4,
                    height: stage == .dragged ? 18 : stage == .hovered ? 16 : 14
                )
                .position(x: played, y: Self.height / 2)
        }
    }

    /// A line where each paragraph near the pointer opens, fainter with the
    /// distance, and a stronger one for the paragraph the page points at, in
    /// the text or here. None shows under the playhead, which stays the one
    /// strong thing on the line.
    private func paragraphMarks(on scale: TimelineScale, clearOf played: CGFloat) -> some View {
        let pointer = dragged ?? hovered
        let shown = marks.indices.filter { index in
            let x = scale.offset(for: marks[index])
            return abs(x - played) >= 3
                && (index == highlighted || scale.clarity(ofMarkAt: x, pointer: pointer) > 0)
        }
        return ForEach(shown, id: \.self) { index in
            let x = scale.offset(for: marks[index])
            let strong = index == highlighted
            Capsule()
                .fill(strong ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: strong ? 2 : 1, height: strong ? 12 : 7)
                .opacity(strong ? 1 : scale.clarity(ofMarkAt: x, pointer: pointer))
                .position(x: x, y: Self.height / 2)
        }
    }

    /// The paragraph a point of the timeline belongs to: the mark itself when
    /// the pointer is on one, otherwise the paragraph being spoken there.
    private func paragraph(at x: CGFloat, on scale: TimelineScale) -> Int? {
        if let exact = scale.mark(near: x, among: marks) { return exact }
        let moment = scale.time(at: x)
        return marks.lastIndex { $0 <= moment } ?? (marks.isEmpty ? nil : 0)
    }
}

/// Drawing and hit testing share the inset that keeps the playhead inside the line.
nonisolated struct TimelineScale {
    /// How far from the pointer a paragraph's mark still shows.
    static let reach: CGFloat = 36

    let width: CGFloat
    let duration: TimeInterval

    var inset: CGFloat { min(2, max(0, width) / 2) }
    var trackWidth: CGFloat { max(0, width - 2 * inset) }

    func offset(for time: TimeInterval) -> CGFloat {
        guard duration.isFinite, duration > 0, time.isFinite else { return inset }
        return inset + trackWidth * min(1, max(0, time / duration))
    }

    func time(at x: CGFloat) -> TimeInterval {
        guard trackWidth > 0, duration.isFinite, duration > 0, x.isFinite else { return 0 }
        return min(1, max(0, (x - inset) / trackWidth)) * duration
    }

    /// How clearly a mark shows, from 0 to 1: fully under the pointer, less
    /// with the distance, and not at all without a pointer over the timeline.
    func clarity(ofMarkAt x: CGFloat, pointer: CGFloat?) -> Double {
        guard let pointer else { return 0 }
        return max(0, 1 - abs(x - pointer) / Self.reach)
    }

    /// The paragraph whose mark a point is on, within a few points of it.
    func mark(near x: CGFloat, among marks: [TimeInterval]) -> Int? {
        guard width > 0, duration > 0 else { return nil }
        let nearest = marks.indices.min {
            abs(offset(for: marks[$0]) - x) < abs(offset(for: marks[$1]) - x)
        }
        guard let nearest, abs(offset(for: marks[nearest]) - x) <= 5 else { return nil }
        return nearest
    }
}
