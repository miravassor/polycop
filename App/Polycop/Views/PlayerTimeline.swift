// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Where the recording is, where its paragraphs open, and where a click
/// lands: a thin line, played in the accent colour up to a narrow upright
/// playhead. A lecture has a paragraph every few points of it, so their marks
/// keep quiet until the pointer comes, and grow around it as under a lens. A
/// small bead marks where the pointer is, and glides after it.
struct PlayerTimeline: View {
    /// The height that takes clicks and holds the playhead at its tallest.
    static let height: CGFloat = 20

    let duration: TimeInterval
    let position: TimeInterval
    let marks: [TimeInterval]
    /// The paragraph under the pointer, in the text or here.
    let pointer: ParagraphPointer
    let jump: (Int) -> Void
    let scrub: (TimeInterval) -> Void
    let reach: (TimeInterval) -> Void
    /// Where the pointer is or last was, so the lens closes where it stood.
    @State private var aim: CGFloat = 0
    @State private var isHovering = false
    @State private var isDragging = false
    /// Whether the lens of marks is out. It opens an update after the pointer
    /// arrives, once its place is set, so that it opens there and does not
    /// slide in from where the pointer last left.
    @State private var isLensOut = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    /// What the reader is doing with the timeline, which its sizes follow.
    private enum Stage { case resting, hovered, dragged }

    private var stage: Stage { isDragging ? .dragged : isHovering ? .hovered : .resting }

    /// The line and the playhead grow under the pointer; where they are
    /// never animates, so a point chosen is shown at once.
    private var growth: Animation? { reducesMotion ? nil : .default }

    /// The bead and the lens glide after the pointer rather than jump to it.
    private var glide: Animation? { reducesMotion ? nil : .snappy }

    /// The bead's diameter.
    private static let bead: CGFloat = 10

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
                            aim = drag.location.x
                            pointer.point(at: scale.paragraph(spokenAt: aim, among: marks))
                            scrub(scale.time(at: drag.location.x))
                        }
                        .onEnded { drag in
                            isDragging = false
                            // Released off the timeline, the pointer is on no paragraph.
                            if !isHovering { pointer.point(at: nil) }
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
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        // Arriving, the bead and the lens open where the
                        // pointer is; they glide from there on. What the
                        // text shows of it does not animate.
                        if isHovering {
                            withAnimation(glide) { aim = location.x }
                        } else {
                            aim = location.x
                            isHovering = true
                        }
                        pointer.point(at: scale.paragraph(spokenAt: location.x, among: marks))
                    case .ended:
                        isHovering = false
                        // A drag goes on past the timeline's edge.
                        if !isDragging { pointer.point(at: nil) }
                    }
                }
                .onChange(of: stage != .resting) { _, isActive in
                    withAnimation(growth) { isLensOut = isActive }
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

    /// The paragraph marks, behind the line and its played part, the stretch
    /// of the paragraph under the pointer, and the playhead over them.
    private func track(on scale: TimelineScale) -> some View {
        let played = scale.offset(for: position)
        return ZStack(alignment: .leading) {
            ParagraphMarks(
                offsets: marks.map(scale.offset(for:)), highlighted: pointer.paragraph,
                playhead: played, pointer: aim, lens: isLensOut ? 1 : 0
            )
            line(.quaternary, width: scale.trackWidth, from: scale.inset)
            line(.tint, width: max(0, played - scale.inset), from: scale.inset)
            if let stretch = scale.stretch(of: pointer.paragraph, among: marks) {
                line(
                    .primary.opacity(0.3), width: stretch.upperBound - stretch.lowerBound,
                    from: stretch.lowerBound)
            }
            // Not while it would cover the playhead, nor during a drag, when
            // the playhead is what the pointer holds.
            let showsBead = stage == .hovered && abs(aim - played) > Self.bead
            ZStack {
                if showsBead {
                    bead.position(x: aim, y: Self.height / 2).transition(.opacity)
                }
            }
            .animation(growth, value: showsBead)
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

    /// Where the pointer is: a drop of glass in the accent colour on macOS 26,
    /// which the player's own glass takes in, and a translucent one before.
    @ViewBuilder private var bead: some View {
        if #available(macOS 26, *) {
            Color.clear
                .frame(width: Self.bead, height: Self.bead)
                .glassEffect(.regular.tint(.accentColor.opacity(0.5)), in: Circle())
        } else {
            Circle().fill(.tint.opacity(0.4)).frame(width: Self.bead, height: Self.bead)
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

/// A line where each paragraph opens: short and faint at rest, taller and
/// clearer around the pointer, and whole for the paragraph the pointer is on
/// in the text. None is drawn under the playhead, which stays the one strong
/// thing on the line. One drawing for all of them: a lecture has hundreds.
private struct ParagraphMarks: View, Animatable {
    let offsets: [CGFloat]
    let highlighted: Int?
    let playhead: CGFloat
    /// Where the lens is, which glides after the pointer.
    var pointer: CGFloat
    /// How far the lens is out: 0 at rest, 1 under the pointer.
    var lens: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pointer, lens) }
        set { (pointer, lens) = (newValue.first, newValue.second) }
    }

    var body: some View {
        Canvas { context, size in
            for (index, x) in offsets.enumerated() where abs(x - playhead) >= 3 {
                let near =
                    index == highlighted ? 1 : lens * TimelineScale.nearness(of: x, to: pointer)
                let width = 1 + 0.5 * near
                let height = 5 + 9 * near
                let mark = CGRect(
                    x: x - width / 2, y: (size.height - height) / 2, width: width, height: height)
                context.opacity = 0.16 + 0.44 * near
                context.fill(
                    Path(roundedRect: mark, cornerRadius: width / 2), with: .style(.primary))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Drawing and hit testing share one scale. The line stops half a point
/// inside its width, where the digits of the times under it have their edge,
/// so that the line and the times start and end together.
nonisolated struct TimelineScale {
    let width: CGFloat
    let duration: TimeInterval

    var inset: CGFloat { min(0.5, max(0, width) / 2) }
    var trackWidth: CGFloat { max(0, width - 2 * inset) }

    func offset(for time: TimeInterval) -> CGFloat {
        guard duration.isFinite, duration > 0, time.isFinite else { return inset }
        return inset + trackWidth * min(1, max(0, time / duration))
    }

    func time(at x: CGFloat) -> TimeInterval {
        guard trackWidth > 0, duration.isFinite, duration > 0, x.isFinite else { return 0 }
        return min(1, max(0, (x - inset) / trackWidth)) * duration
    }

    /// How much a mark is under the pointer's lens, from 1 at the pointer
    /// down to nothing some forty points away.
    static func nearness(of x: CGFloat, to pointer: CGFloat) -> CGFloat {
        let distance = (x - pointer) / 18
        return exp(-distance * distance)
    }

    /// The paragraph a point of the timeline belongs to: the one that opens
    /// within a few points of it, otherwise the one being spoken there.
    func paragraph(at x: CGFloat, among marks: [TimeInterval]) -> Int? {
        guard width > 0, duration > 0, !marks.isEmpty else { return nil }
        let nearest = marks.indices.min {
            abs(offset(for: marks[$0]) - x) < abs(offset(for: marks[$1]) - x)
        }
        if let nearest, abs(offset(for: marks[nearest]) - x) <= 5 { return nearest }
        return paragraph(spokenAt: x, among: marks)
    }

    /// The paragraph being spoken at a point of the timeline.
    func paragraph(spokenAt x: CGFloat, among marks: [TimeInterval]) -> Int? {
        guard width > 0, duration > 0, !marks.isEmpty else { return nil }
        let moment = time(at: x)
        return marks.lastIndex { $0 <= moment } ?? 0
    }

    /// The stretch of the line a paragraph covers, from where it opens to
    /// where the next one does.
    func stretch(of paragraph: Int?, among marks: [TimeInterval]) -> ClosedRange<CGFloat>? {
        guard let paragraph, marks.indices.contains(paragraph) else { return nil }
        let start = offset(for: marks[paragraph])
        let end =
            paragraph + 1 < marks.count ? offset(for: marks[paragraph + 1]) : inset + trackWidth
        return start...max(start, end)
    }
}

#Preview {
    PlayerTimeline(
        duration: 5400, position: 2000,
        marks: stride(from: 0.0, to: 5400, by: 37).map { $0 },
        pointer: ParagraphPointer(), jump: { _ in }, scrub: { _ in }, reach: { _ in }
    )
    .padding()
    .frame(width: 500)
}
