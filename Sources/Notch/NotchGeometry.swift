import AppKit

/// Physical measurements of the built-in notch (or a sensible fallback on
/// Macs / external displays without one).
struct NotchGeometry {
    let screen: NSScreen
    let notchSize: CGSize          // the black cut-out itself
    let hasNotch: Bool

    /// Collapsed pill size. Matches the notch exactly when one exists so the
    /// window is invisible against the black cut-out.
    var collapsedSize: CGSize {
        if hasNotch {
            return CGSize(width: notchSize.width, height: notchSize.height)
        }
        return CGSize(width: 190, height: 32)
    }

    /// Live-session bar: flanks the notch with the logo + status + tokens,
    /// exactly as tall as the notch so it sits flush with the menu bar.
    var activitySize: CGSize {
        CGSize(width: notchSize.width + 172, height: notchSize.height)
    }

    /// Compact bar shown while files are being held.
    var filesSize: CGSize {
        CGSize(width: notchSize.width + 184, height: notchSize.height)
    }

    /// Expanded panel size (the drawer that drops down on hover). Compact —
    /// tall enough that its content clears the physical notch at the top.
    var expandedSize: CGSize {
        CGSize(width: 384, height: 156)
    }

    /// The window is fixed at the largest state and stays transparent; the
    /// shape animates inside it (so hover never resizes the window → smooth).
    var windowSize: CGSize {
        CGSize(width: max(expandedSize.width, filesSize.width) + 8,
               height: expandedSize.height + 4)
    }

    /// The visible shape size for the current state — used identically by the
    /// SwiftUI view (to draw) and the controller (to hit-test / track hover).
    func shapeSize(presentation: Presentation, expanded: Bool, dragOver: Bool) -> CGSize {
        if dragOver || expanded { return expandedSize }
        switch presentation {
        case .idle:            return collapsedSize
        case .coding, .media:  return activitySize
        case .files:           return filesSize
        }
    }

    static func detect(on screen: NSScreen? = nil) -> NotchGeometry {
        let scr = screen ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
        let topInset = scr.safeAreaInsets.top
        let hasNotch = topInset > 0

        var notchWidth: CGFloat = 190
        if hasNotch {
            // The two auxiliary areas flank the notch. What's left in the
            // middle is the notch width.
            let left = scr.auxiliaryTopLeftArea?.width ?? 0
            let right = scr.auxiliaryTopRightArea?.width ?? 0
            if left > 0 && right > 0 {
                notchWidth = scr.frame.width - left - right
            }
        }
        let notchHeight = hasNotch ? topInset : 32
        return NotchGeometry(
            screen: scr,
            notchSize: CGSize(width: notchWidth, height: notchHeight),
            hasNotch: hasNotch
        )
    }

    /// Frame (screen coordinates, origin bottom-left) for a window of `size`
    /// centered horizontally with its top edge pinned to the physical top.
    func topCenteredFrame(for size: CGSize) -> NSRect {
        let f = screen.frame
        let x = f.origin.x + (f.width - size.width) / 2
        let y = f.origin.y + f.height - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
