// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Where the recording is, and where a click lands: a thin line, played in
/// the accent colour up to a narrow upright playhead. It carries no mark for
/// each paragraph, which a lecture has every few points of it: only the one
/// the pointer is on in the text.
struct PlayerTimeline: View {
    /// The height that takes clicks and holds the playhead at its tallest.
    static let height: CGFloat = 20

    let duration: TimeInterval
    let position: TimeInterval
    let marks: [TimeInterval]
    let highlighted: Int?
    let jump: (Int) -> Void
    let scrub: (TimeInterval) -> Void
    let reach: (TimeInterval) -> Void
    @State private var isHovering = false
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    /// What the reader is doing with the timeline, which its sizes follow.
    private enum Stage { case resting, hovered, dragged }

    private var stage: Stage { isDragging ? .dragged : isHovering ? .hovered : .resting }

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
                            scrub(scale.time(at: drag.location.x))
                        }
                        .onEnded { drag in
                            isDragging = false
                            reach(scale.time(at: drag.location.x))
                        }
                )
                // A double click asks to read that passage, not only to hear it.
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { tap in
                            if let paragraph = scale.paragraph(at: tap.location.x, among: marks) {
                                jump(paragraph)
                            }
                        }
                )
                .onHover { isHovering = $0 }
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

    /// The line, its played part, the paragraph pointed at and the playhead.
    private func track(on scale: TimelineScale) -> some View {
        let played = scale.offset(for: position)
        return ZStack(alignment: .leading) {
            line(.quaternary, width: scale.trackWidth, from: scale.inset)
            line(.tint, width: max(0, played - scale.inset), from: scale.inset)
            // Where the paragraph under the pointer, in the text, opens; the
            // playhead says it alone when it is there.
            if let highlighted, marks.indices.contains(highlighted),
                abs(scale.offset(for: marks[highlighted]) - played) >= 3
            {
                Capsule()
                    .fill(.primary)
                    .frame(width: 2, height: 12)
                    .position(x: scale.offset(for: marks[highlighted]), y: Self.height / 2)
            }
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
}

/// Drawing and hit testing share the inset that keeps the playhead inside the line.
nonisolated struct TimelineScale {
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

    /// The paragraph a point of the timeline belongs to: the one that opens
    /// within a few points of it, otherwise the one being spoken there.
    func paragraph(at x: CGFloat, among marks: [TimeInterval]) -> Int? {
        guard width > 0, duration > 0, !marks.isEmpty else { return nil }
        let nearest = marks.indices.min {
            abs(offset(for: marks[$0]) - x) < abs(offset(for: marks[$1]) - x)
        }
        if let nearest, abs(offset(for: marks[nearest]) - x) <= 5 { return nearest }
        let moment = time(at: x)
        return marks.lastIndex { $0 <= moment } ?? 0
    }
}
