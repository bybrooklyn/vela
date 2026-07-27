#if os(macOS)
    import SwiftUI

    /// Where a bubble sits within a run of consecutive messages from one sender.
    ///
    /// Messaging apps do not draw every message as an identical rounded box:
    /// consecutive messages tuck into each other by tightening the corners where
    /// they meet. That, and nothing else, is what makes a thread read as a
    /// conversation — Signal and Google Messages both do it without any tail.
    enum BubblePosition {
        /// Alone in its run — fully rounded.
        case single
        /// Opens a run — the bottom corner on the sender's side tightens.
        case first
        /// Inside a run — both corners on the sender's side tighten.
        case middle
        /// Closes a run — the top corner on the sender's side tightens.
        case last

        var tightensTop: Bool { self == .middle || self == .last }
        var tightensBottom: Bool { self == .middle || self == .first }
    }

    /// A message bubble: fully rounded away from the sender, tightened where it
    /// meets its neighbours in a run.
    struct BubbleShape: Shape {
        let isOutgoing: Bool
        let position: BubblePosition
        var radius: CGFloat = Metrics.bubbleRadius
        /// Tightened corners keep a little softness rather than going square.
        var tightRadius: CGFloat = Metrics.bubbleTightRadius

        func path(in rect: CGRect) -> Path {
            let nearTop = position.tightensTop ? tightRadius : radius
            let nearBottom = position.tightensBottom ? tightRadius : radius

            // "Near" is the sender's side: right for outgoing, left for incoming.
            return roundedBody(
                in: rect,
                topLeft: isOutgoing ? radius : nearTop,
                topRight: isOutgoing ? nearTop : radius,
                bottomRight: isOutgoing ? nearBottom : radius,
                bottomLeft: isOutgoing ? radius : nearBottom
            )
        }

        private func roundedBody(
            in rect: CGRect,
            topLeft: CGFloat,
            topRight: CGFloat,
            bottomRight: CGFloat,
            bottomLeft: CGFloat
        ) -> Path {
            // Radii cannot exceed half the shorter side or the curves overlap.
            let limit = min(rect.width, rect.height) / 2
            let tl = min(topLeft, limit)
            let tr = min(topRight, limit)
            let br = min(bottomRight, limit)
            let bl = min(bottomLeft, limit)

            var path = Path()
            path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + tr),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - bl),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + tl, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            path.closeSubpath()
            return path
        }
    }
#endif
