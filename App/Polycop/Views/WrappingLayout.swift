// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Views side by side at their own size, in order, starting a new row where the
/// next one does not fit. The system has no such layout: an `HStack` keeps to one
/// row.
struct WrappingLayout: Layout {
    private let spacing: CGFloat = 8
    private let rowSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let frames = frames(of: subviews, within: proposal.width ?? .infinity)
        return CGSize(
            width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let frames = frames(of: subviews, within: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(of subviews: Subviews, within width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + rowSpacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
