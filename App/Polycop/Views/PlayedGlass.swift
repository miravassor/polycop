// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The part of the timeline already played, on macOS 26: a line of glass in
/// the accent colour swelling into a round knob, one shape, which grows while
/// dragged. A small drop follows the pointer and melts into the knob as it
/// comes near, the two in one container. While playing, light moves along the
/// glass, a touch brighter and darker in turn.
@available(macOS 26, *)
struct PlayedGlass: View {
    /// Where the line starts and ends, across the timeline.
    let start: CGFloat
    let end: CGFloat
    /// Where the pointer is or last was.
    let pointer: CGFloat
    let isHovering: Bool
    let isDragging: Bool
    /// The playing speed, 0 while paused.
    let rate: Double
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var motion = FlowMotion()
    @State private var isEasing = false

    /// Points a second for the long wave of the light. It stays still with
    /// Reduce Motion, in an inactive window and in Low Power Mode, which a
    /// redraw for another reason picks up.
    private var speed: Double {
        guard !reducesMotion, appearsActive, !ProcessInfo.processInfo.isLowPowerModeEnabled
        else { return 0 }
        return rate * 24
    }

    var body: some View {
        GeometryReader { geometry in
            let middle = geometry.size.height / 2
            let shape = PlayedShape(
                start: start, end: end, line: isHovering || isDragging ? 7.5 : 5.5,
                knob: Self.knob(isDragging: isDragging))
            GlassEffectContainer(spacing: 14) {
                ZStack {
                    // One outline for the line and the knob, so no joint shows
                    // between them.
                    flow(across: geometry.size.width)
                        .clipShape(shape)
                        .glassEffect(.regular.tint(.accentColor), in: shape)
                    if Self.showsDrop(
                        at: pointer, end: end, isHovering: isHovering, isDragging: isDragging)
                    {
                        Color.clear
                            .frame(width: Self.drop, height: Self.drop)
                            .glassEffect(.regular.tint(.accentColor.opacity(0.6)), in: Circle())
                            // Fading rather than morphing, which leaves a dot
                            // behind as it shrinks into the knob.
                            .glassEffectTransition(.materialize)
                            .position(x: pointer, y: middle)
                    }
                }
            }
        }
        .shadow(color: .accentColor.opacity(0.25), radius: 2)
        .allowsHitTesting(false)
        .onChange(of: speed, initial: true) { _, speed in
            motion.change(to: speed, at: .now)
            isEasing = true
        }
        .task(id: motion.changed) {
            try? await Task.sleep(for: .seconds(FlowMotion.easing))
            isEasing = false
        }
    }

    /// Whether the pointer's drop shows: on the part still to play, clear of
    /// the knob, and not while dragging. Over the line or the knob it would
    /// darken them.
    static func showsDrop(at pointer: CGFloat, end: CGFloat, isHovering: Bool, isDragging: Bool)
        -> Bool
    {
        isHovering && !isDragging && pointer > end + (knob(isDragging: false) + drop) / 2
    }

    /// The knob's diameter, larger while dragged.
    static func knob(isDragging: Bool) -> CGFloat { isDragging ? 17 : 13 }

    /// The pointer's drop's diameter.
    static let drop: CGFloat = 12

    /// The light moving along the glass, across the timeline.
    private func flow(across width: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: speed == 0 && !isEasing)) {
            context in
            LinearGradient(
                gradient: Self.flow(across: width, travelled: motion.distance(at: context.date)),
                startPoint: .leading, endPoint: .trailing)
        }
    }

    /// Two soft waves of different lengths and speeds summed, so the light
    /// never repeats as stripes. Clear between them, so the glass stays glass.
    private static func flow(across width: CGFloat, travelled: Double) -> Gradient {
        let count = max(4, Int(width / 6))
        return Gradient(
            stops: (0...count).map { index in
                let location = Double(index) / Double(count)
                let x = location * width
                let long = sin((x - travelled) / 24)
                let short = sin((x - travelled * 37 / 24) / 14 + 1.3)
                // Between -1 and 1: brighter above zero, darker below.
                let level = 0.6 * long + 0.4 * short
                let color =
                    level >= 0
                    ? Color.white.opacity(0.2 * level) : Color.black.opacity(-0.08 * level)
                return Gradient.Stop(color: color, location: location)
            })
    }
}

/// The line and the knob as one outline, drawn in one stroke: the line's
/// round start, along to the knob, swelling up into it over a few points,
/// around its round end and back. Its sizes animate with the timeline's
/// springs.
@available(macOS 26, *)
private nonisolated struct PlayedShape: Shape {
    var start: CGFloat
    var end: CGFloat
    var line: CGFloat
    /// The knob's diameter.
    var knob: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(line, knob) }
        set { (line, knob) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let middle = rect.midY
        let radius = knob / 2
        let lineRadius = line / 2
        // The knob, centred on the position; the line joins its curve on the
        // upper and lower left.
        let centre = CGPoint(x: end, y: middle)
        let join = Angle.degrees(130)
        let joinX = centre.x + radius * cos(join.radians)
        let joinY = radius * sin(join.radians)
        // The circle's direction at the join, to meet it without a corner.
        let tangent = CGVector(dx: sin(join.radians), dy: -cos(join.radians))
        let reach: CGFloat = 3
        let flare = max(start + lineRadius, joinX - 6)
        var path = Path()
        path.move(to: CGPoint(x: start + lineRadius, y: middle - lineRadius))
        path.addLine(to: CGPoint(x: flare, y: middle - lineRadius))
        path.addCurve(
            to: CGPoint(x: joinX, y: middle - joinY),
            control1: CGPoint(x: flare + 2.5, y: middle - lineRadius),
            control2: CGPoint(
                x: joinX - reach * tangent.dx, y: middle - joinY + reach * tangent.dy))
        path.addArc(
            center: centre, radius: radius, startAngle: -join, endAngle: join, clockwise: false)
        path.addCurve(
            to: CGPoint(x: flare, y: middle + lineRadius),
            control1: CGPoint(
                x: joinX - reach * tangent.dx, y: middle + joinY - reach * tangent.dy),
            control2: CGPoint(x: flare + 2.5, y: middle + lineRadius))
        path.addLine(to: CGPoint(x: start + lineRadius, y: middle + lineRadius))
        path.addArc(
            center: CGPoint(x: start + lineRadius, y: middle), radius: lineRadius,
            startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// How far the flow has travelled, its speed easing from one value to the
/// next over a moment rather than jumping, so a pause slows it to rest.
nonisolated struct FlowMotion: Equatable {
    static let easing: TimeInterval = 0.6

    /// When the speed last changed, the distance then, and the speeds it
    /// eases between.
    private(set) var changed = Date.distantPast
    private var start = 0.0
    private var from = 0.0
    private var to = 0.0

    func speed(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(changed)
        return elapsed >= Self.easing ? to : from + (to - from) * max(0, elapsed) / Self.easing
    }

    func distance(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(changed))
        let eased = min(elapsed, Self.easing)
        return start + from * eased + (to - from) * eased * eased / (2 * Self.easing)
            + to * (elapsed - eased)
    }

    mutating func change(to speed: Double, at date: Date) {
        start = distance(at: date)
        from = self.speed(at: date)
        to = speed
        changed = date
    }
}
