// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A smallest size given without measuring the content. SwiftUI asks the
/// window, and each column of the split view, for its minimum after every
/// change; a frame with a minimum would measure the whole page to answer.
struct MinimumSize: Layout {
    let size: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: max(size.width, proposal.width ?? size.width),
            height: max(size.height, proposal.height ?? size.height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }

    // Without these, a stack asking for the alignment guides would have the
    // page placed, and so measured, to read them.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) -> CGFloat? { nil }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) -> CGFloat? { nil }
}

extension View {
    func minimumSize(width: CGFloat, height: CGFloat) -> some View {
        MinimumSize(size: CGSize(width: width, height: height)) { self }
    }
}
