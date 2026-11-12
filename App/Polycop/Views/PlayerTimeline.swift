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
    /// Where the pointer is over the timeline, hovering or dragging.
    @State private var pointer: CGFloat?
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    /// What the reader is doing with the timeline, which its sizes follow.
    private enum Stage { case resting, hovered, dragged }

    private var stage: Stage {
        isDragging ? .dragged : pointer != nil ? .hovered : .resting
    }

    /// The line and the playhead grow under the pointer; where they are
    /// never animates, so a point chosen is shown at once.
    private var growth: Animation? { reducesMotion ? nil : .default }

    var body: some View {
        GeometryReader { geometry in
            let scale = TimelineScale(width: geometry.size.width, duration: duration)
            track(on: scale)
                .frame(height: Self.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            isDragging = true
                            point(at: drag.location.x, on: scale)
                            scrub(scale.time(at: drag.location.x))
                        }
                        .onEnded { drag in
                            isDragging = false
                            let x = drag.location.x
                            point(at: (0...scale.width).contains(x) ? x : nil, on: scale)
                            reach(scale.time(at: x))
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
                    case .active(let location):
                        point(at: location.x, on: scale)
                    case .ended:
                        // A drag goes on past the timeline's edge.
                        if !isDragging { point(at: nil, on: scale) }
                    }
                }
                .allowsHitTesting(duration > 0)
                .accessibilityElement()
                .accessibilityLabel("Timeline")
                .accessibilityValue(spoken)
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

    /// The time played and the length, as VoiceOver says them in place of
    /// the two numbers under the timeline.
    private var spoken: String {
        duration > 0
            ? "\(formattedDuration(position)) of \(formattedDuration(duration))"
            : formattedDuration(position)
    }

    /// Where the pointer is, for the marks here and for the page, which shows
    /// the paragraph in the text.
    private func point(at x: CGFloat?, on scale: TimelineScale) {
        pointer = x
        hover(x.flatMap { scale.mark(near: $0, among: marks) })
    }

    /// The line, its played part, the marks around the pointer and the playhead.
    private func track(on scale: TimelineScale) -> some View {
        let played = scale.offset(for: position)
        return ZStack(alignment: .leading) {
            line(.quaternary, width: scale.trackWidth, from: scale.inset)
            line(.tint, width: max(0, played - scale.inset), from: scale.inset)
            paragraphMarks(on: scale, clearOf: played)
            Capsule()
                .fill(.tint)
                .frame(
                    width: stage == .resting ? 3 : 4,
                    height: stage == .dragged ? 18 : stage == .hovered ? 16 : 14
                )
                .animation(growth, value: stage)
                .position(x: played, y: Self.height / 2)
        }
    }

    /// A stretch of the line, thicker under the pointer.
    private func line(_ style: some ShapeStyle, width: CGFloat, from start: CGFloat) -> some View {
        Capsule()
            .fill(style)
            .frame(height: stage == .resting ? 3 : 5)
            .animation(growth, value: stage)
            .frame(width: width)
            .offset(x: start)
    }

    /// A line where each paragraph near the pointer opens, fainter with the
    /// distance, and a stronger one for the paragraph the page points at, in
    /// the text or here. None shows under the playhead, which stays the one
    /// strong thing on the line.
    private func paragraphMarks(on scale: TimelineScale, clearOf played: CGFloat) -> some View {
        let shown = scale.marksShown(
            among: marks, pointer: pointer, highlighted: highlighted, clearOf: played)
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

    /// The paragraphs whose marks show: those around the pointer and the one
    /// the page points at, but none under the playhead.
    func marksShown(
        among marks: [TimeInterval], pointer: CGFloat?, highlighted: Int?, clearOf played: CGFloat
    ) -> [Int] {
        marks.indices.filter { index in
            let x = offset(for: marks[index])
            return abs(x - played) >= 3
                && (index == highlighted || clarity(ofMarkAt: x, pointer: pointer) > 0)
        }
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
