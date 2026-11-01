// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Where the recording is, where its paragraphs open, and where a click lands.
struct PlayerTimeline: View {
    let duration: TimeInterval
    let position: TimeInterval
    let marks: [TimeInterval]
    let highlighted: Int?
    let current: Int?
    /// The playing speed, 0 while paused, which the played glass flows at.
    let rate: Double
    let hover: (Int?) -> Void
    let jump: (Int) -> Void
    let scrub: (TimeInterval) -> Void
    let reach: (TimeInterval) -> Void
    @State private var pointer: CGFloat = 0
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = TimelineScale(width: width, duration: duration)
            track(on: scale, played: scale.offset(for: position))
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !isDragging {
                                withAnimation(.spring(duration: 0.35, bounce: 0.4)) {
                                    isDragging = true
                                }
                            }
                            scrub(time(at: drag.location.x, across: width))
                        }
                        .onEnded { drag in
                            withAnimation(.spring(duration: 0.5, bounce: 0.5)) {
                                isDragging = false
                            }
                            reach(time(at: drag.location.x, across: width))
                        }
                )
                // A double click asks to read that passage, not only to hear it.
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { tap in
                            if let paragraph = paragraph(at: tap.location.x, across: width) {
                                jump(paragraph)
                            }
                        }
                )
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        withAnimation(.spring(duration: 0.3, bounce: 0.3)) {
                            pointer = point.x
                            isHovering = true
                        }
                        hover(mark(near: point.x, across: width))
                    case .ended:
                        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { isHovering = false }
                        hover(nil)
                    }
                }
                .allowsHitTesting(duration > 0)
                .accessibilityElement()
                .accessibilityLabel("Timeline")
                .accessibilityValue(PlayerBar.clock(position))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: reach(min(duration, position + 5))
                    case .decrement: reach(max(0, position - 5))
                    @unknown default: break
                    }
                }
        }
        .frame(height: 28)
    }

    /// The track, the played part and the paragraph marks.
    private func track(on scale: TimelineScale, played: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            if #available(macOS 26, *) {
                // The track stops at the knob's edges. A mark under the knob or
                // the pointer's drop shows on the glass, larger, as through a
                // lens, since the glass would blur it away.
                let knob = PlayedGlass.knob(isDragging: isDragging)
                let half = knob / 2 - 1
                line(from: scale.inset, to: played - half)
                line(from: played + half, to: scale.inset + scale.trackWidth)
                paragraphMarks(on: scale)
                PlayedGlass(
                    start: scale.inset, end: played, pointer: pointer,
                    isHovering: isHovering, isDragging: isDragging, rate: rate)
                magnifiedMarks(
                    on: scale, under: (played - half)...(played + half), height: knob - 4)
                if PlayedGlass.showsDrop(
                    at: pointer, end: played, isHovering: isHovering, isDragging: isDragging)
                {
                    let drop = PlayedGlass.drop / 2
                    magnifiedMarks(
                        on: scale, under: (pointer - drop)...(pointer + drop), height: drop * 2 - 3)
                }
            } else {
                line(from: scale.inset, to: scale.inset + scale.trackWidth)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(0, played - scale.inset), height: 4)
                    .offset(x: scale.inset)
                paragraphMarks(on: scale)
                Circle()
                    .fill(.tint)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .position(x: played, y: 14)
            }
        }
    }

    /// A stretch of the track.
    private func line(from start: CGFloat, to end: CGFloat) -> some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: max(0, end - start), height: 4)
            .offset(x: start)
    }

    /// The marks under a piece of glass, bolder and within its height, as
    /// seen through it.
    private func magnifiedMarks(
        on scale: TimelineScale, under glass: ClosedRange<CGFloat>, height: CGFloat
    ) -> some View {
        ForEach(marks.indices, id: \.self) { index in
            let x = scale.offset(for: marks[index])
            if glass.contains(x) {
                Capsule()
                    .fill(.primary.opacity(0.55))
                    .frame(width: 2, height: height)
                    .position(x: x, y: 14)
            }
        }
    }

    /// A line at each paragraph's start, stronger under the pointer and for
    /// the one playing.
    private func paragraphMarks(on scale: TimelineScale) -> some View {
        ForEach(marks.indices, id: \.self) { index in
            let x = scale.offset(for: marks[index])
            let strong = index == highlighted || index == current
            Rectangle()
                .fill(style(ofMark: index))
                .frame(width: strong ? 2 : 1, height: strong ? 18 : 12)
                .position(x: x, y: 14)
        }
    }

    /// The mark of the paragraph playing carries the accent, as the played
    /// part does; the one under the pointer stands out.
    private func style(ofMark index: Int) -> AnyShapeStyle {
        if index == current { return AnyShapeStyle(.tint) }
        return index == highlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    /// The paragraph whose mark the pointer is on, within a few points of it.
    private func mark(near x: CGFloat, across width: CGFloat) -> Int? {
        guard width > 0, duration > 0 else { return nil }
        let scale = TimelineScale(width: width, duration: duration)
        let nearest = marks.indices.min {
            abs(scale.offset(for: marks[$0]) - x) < abs(scale.offset(for: marks[$1]) - x)
        }
        guard let nearest, abs(scale.offset(for: marks[nearest]) - x) <= 5 else { return nil }
        return nearest
    }

    /// The paragraph a point of the timeline belongs to: the mark itself when
    /// the pointer is on one, otherwise the paragraph being spoken there.
    private func paragraph(at x: CGFloat, across width: CGFloat) -> Int? {
        if let exact = mark(near: x, across: width) { return exact }
        let moment = time(at: x, across: width)
        return marks.lastIndex { $0 <= moment } ?? (marks.isEmpty ? nil : 0)
    }

    private func time(at x: CGFloat, across width: CGFloat) -> TimeInterval {
        TimelineScale(width: width, duration: duration).time(at: x)
    }
}

/// Drawing and hit testing share the inset that keeps the thumb inside the track.
nonisolated struct TimelineScale {
    let width: CGFloat
    let duration: TimeInterval

    var inset: CGFloat { min(7, max(0, width) / 2) }
    var trackWidth: CGFloat { max(0, width - 2 * inset) }

    func offset(for time: TimeInterval) -> CGFloat {
        guard duration.isFinite, duration > 0, time.isFinite else { return inset }
        return inset + trackWidth * min(1, max(0, time / duration))
    }

    func time(at x: CGFloat) -> TimeInterval {
        guard trackWidth > 0, duration.isFinite, duration > 0, x.isFinite else { return 0 }
        return min(1, max(0, (x - inset) / trackWidth)) * duration
    }
}
