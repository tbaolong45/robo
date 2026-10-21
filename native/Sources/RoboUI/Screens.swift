// The displays, in the two coordinate systems robo meets.
//
// AppKit: global, origin at the bottom-left of the PRIMARY display, y up (NSScreen.frame, NSWindow.frame,
// NSEvent.mouseLocation). Roamer, `lookAt` and the drag maths: origin at the top-left of the primary, y down
// (what Qt and Quartz use), so a screen to the left has a negative x and one above the primary a negative y.
// The only thing that links them is the primary's height.
import AppKit
import RoboCore

/// One display as AppKit reports it (AppKit coordinates).
struct Display: Equatable {
    var frame: CGRect
    var visible: CGRect  // below the menu bar, beside the Dock
    init(frame: CGRect, visible: CGRect) { (self.frame, self.visible) = (frame, visible) }

    /// Every connected display; the first is the primary (the one with the menu bar, at the origin).
    static func current() -> [Display] {
        NSScreen.screens.map { Display(frame: $0.frame, visible: $0.visibleFrame) }
    }
}

/// Converts between AppKit's y-up space and Roamer's y-down space for one arrangement of displays.
struct ScreenSpace: Equatable {
    let primaryHeight: Double

    /// nil when there is no display at all (a display asleep for a moment): keep the last layout.
    init?(_ displays: [Display]) {
        guard let primary = displays.first else { return nil }
        primaryHeight = primary.frame.height
    }

    /// A rectangle (a screen's visible area) as a Roamer `Rect`: y = primaryHeight - (origin.y + height).
    func rect(_ r: CGRect) -> Rect {
        Rect(r.origin.x, primaryHeight - (r.origin.y + r.height), r.width, r.height)
    }

    /// Where robo may be, for `Roamer.setScreens`: the usable area (below the menu bar, beside the Dock) of the main display
    /// and of no other. It does not float on to a second monitor, and a drag onto one is pulled back to the main display's edge
    /// (the user's request, 2026-10-21). Empty only when there is no display at all.
    func roamArea(_ displays: [Display]) -> [Rect] { displays.prefix(1).map { rect($0.visible) } }

    /// The top-left of a window frame, where the Roamer keeps the window.
    func topLeft(of frame: CGRect) -> Vec { Vec(frame.origin.x, primaryHeight - (frame.origin.y + frame.height)) }

    /// The window frame (for `setFrame`) of a window of `size` whose top-left is at `pos`.
    func frame(topLeft pos: Vec, size: Vec) -> CGRect {
        CGRect(x: pos.x, y: primaryHeight - pos.y - size.y, width: size.x, height: size.y)
    }

    /// An AppKit point (the mouse) in Roamer space.
    func point(_ p: CGPoint) -> Vec { Vec(p.x, primaryHeight - p.y) }

    /// The display a Roamer-space point is on; the nearest one when it is in a gap, nil with no displays.
    func display(at pos: Vec, in displays: [Display]) -> Display? {
        let p = CGPoint(x: pos.x, y: primaryHeight - pos.y)
        if let d = displays.first(where: { $0.frame.contains(p) }) { return d }
        func gap(_ f: CGRect) -> Double {
            let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
            return dx * dx + dy * dy
        }
        return displays.min { gap($0.frame) < gap($1.frame) }
    }
}
