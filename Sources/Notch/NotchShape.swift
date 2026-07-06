import SwiftUI

/// The dynamic-island silhouette: flush with the top of the screen, with small
/// concave fillets at the top so it flows out of the menu bar (instead of
/// looking like a plain box), and generously rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 10

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let br = min(bottomRadius, min(rect.width, rect.height) / 2)
        let tr = min(topRadius, min(rect.width, rect.height) / 2)
        var p = Path()
        // Top-left: full-width top edge curving inward (concave) to the body.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        // Left side down to the rounded bottom-left.
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        // Bottom edge to rounded bottom-right.
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        // Right side up, then concave fillet back to the top edge.
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
