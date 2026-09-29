import SwiftUI

/// Sizes a video to its own shape: full width for landscape video, and at
/// most `maxHeight` tall (centred) for portrait video, instead of a fixed
/// box padded with black bars. `minHeight` keeps YouTube's player at the
/// 200 pt its terms require.
struct VideoFrameLayout: Layout {
    var aspectRatio: CGFloat
    var maxHeight: CGFloat
    var minHeight: CGFloat = 0
    /// Whether the content spans the full width (YouTube letterboxes inside
    /// its own player) or hugs the video's shape.
    var fillsWidth = false

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let proposed = proposal.width ?? .infinity
        let width = proposed.isFinite ? proposed : maxHeight * max(aspectRatio, 0.1)
        return CGSize(
            width: width,
            height: Self.height(
                forWidth: width,
                aspectRatio: aspectRatio,
                maxHeight: maxHeight,
                minHeight: minHeight
            )
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let width = fillsWidth || aspectRatio <= 0
            ? bounds.width
            : min(bounds.width, bounds.height * aspectRatio)
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
    }

    static func height(
        forWidth width: CGFloat,
        aspectRatio: CGFloat,
        maxHeight: CGFloat,
        minHeight: CGFloat
    ) -> CGFloat {
        guard aspectRatio > 0, width.isFinite, width > 0 else {
            return max(minHeight, maxHeight)
        }
        return max(minHeight, min(width / aspectRatio, maxHeight))
    }
}
