// The face, painted with Core Graphics: port of render_params in src/robo/face/widget.py.
//
// The context is y-down (an NSView with isFlipped, or `image(...)` below), so the Qt coordinates port 1:1.
// Qt angles are counter-clockwise on screen from 3 o'clock; here an angle is just the number in
// (cx + r cos a, cy + r sin a), so the arcs are built from explicit Bezier pieces and never depend on
// whether `addArc(clockwise:)` is inverted by the flip.
import AppKit
import CoreText
import RoboCore

enum FaceRender {
    static let W = 320.0, H = 240.0  // logical canvas; scaled to fit the view
    static let eyeX = 64.0, eyeY = 102.0, eyeW = 66.0, eyeH = 78.0
    static let mouthY = 176.0, mouthW = 46.0
    static let bg = RGBA(r: 9, g: 13, b: 22, a: 255)
    static let screen = RGBA(r: 18, g: 26, b: 42, a: 255)  // the face screen: centre colour (bg is the edge)

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func rgb(_ c: RGBA) -> CGColor {
        CGColor(colorSpace: srgb, components: [CGFloat(c.r) / 255, CGFloat(c.g) / 255, CGFloat(c.b) / 255, CGFloat(c.a) / 255])!
    }

    /// QColor.fromHsvF(h, s, v, a): h in 0..<1.
    private static func hsv(_ h: Double, _ s: Double, _ v: Double, _ a: Double) -> CGColor {
        let h6 = h * 6, whole = h6.rounded(.down), f = h6 - whole
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch Int(whole) % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return CGColor(colorSpace: srgb, components: [r, g, b, a].map { CGFloat($0) })!
    }

    private static func colour(_ p: FaceParams, _ alpha: Double = 1, value: Double = 1) -> CGColor {
        var hue = p.hue.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        return hsv(hue / 360, min(1, max(0, p.sat)), value, alpha)
    }

    private static func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, v)) }

    private static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    /// An arc of the circle/ellipse in `box`, added as Bezier pieces: from angle `from` through `sweep`
    /// (radians; positive goes clockwise on screen because y points down). Continues the current subpath.
    private static func arc(_ path: CGMutablePath, in box: CGRect, from: Double, sweep: Double) {
        let c = pt(box.midX, box.midY), rx = box.width / 2, ry = box.height / 2
        let pieces = max(1, Int((abs(sweep) / (Double.pi / 2)).rounded(.up)))
        let step = sweep / Double(pieces), k = 4.0 / 3.0 * tan(step / 4)
        var a = from
        for _ in 0..<pieces {
            let (c0, s0, c1, s1) = (cos(a), sin(a), cos(a + step), sin(a + step))
            path.addCurve(to: pt(c.x + rx * c1, c.y + ry * s1),
                          control1: pt(c.x + rx * (c0 - k * s0), c.y + ry * (s0 + k * c0)),
                          control2: pt(c.x + rx * (c1 + k * s1), c.y + ry * (s1 - k * c1)))
            a += step
        }
    }

    /// One eye (side -1 left, +1 right) with lids carved out.
    static func eye(_ p: FaceParams, side: Double, ox: Double, oy: Double) -> CGPath {
        let s = 1 + 0.22 * p.skew * side
        let shut = side < 0 ? 1 - 0.92 * clamp(p.wink) : 1.0
        let w = eyeW * p.eyeW * s, h = max(4.0, eyeH * p.eyeH * s * shut)
        let cx = W / 2 + side * eyeX + ox, cy = eyeY + oy
        let r = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        let rad = min(w, h) / 2 * clamp(p.eyeRound)
        var path = CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        let (inner, outer) = side < 0 ? (r.maxX, r.minX) : (r.minX, r.maxX)
        let top = clamp(p.lidTop), ang = clamp(p.lidAngle, -1, 1)
        let yi = r.minY + h * (top + ang / 2), yo = r.minY + h * (top - ang / 2)
        if max(yi, yo) > r.minY {
            let dx = (outer - inner) / 2, dy = (yo - yi) / 2  // extend the lid line past both edges
            let a = pt(inner - dx, yi - dy), b = pt(outer + dx, yo + dy)
            let lid = CGMutablePath()
            lid.move(to: a)
            for q in [b, pt(b.x, r.minY - h), pt(a.x, r.minY - h)] { lid.addLine(to: q) }
            lid.closeSubpath()
            path = path.subtracting(lid)
        }
        let bot = clamp(p.lidBottom)
        if bot > 0.01 && (side > 0 || p.wink < 0.5) {
            let ew = w * 1.5, topY = r.maxY - h * bot * 1.1
            path = path.subtracting(CGPath(ellipseIn: CGRect(x: cx - ew / 2, y: topY, width: ew, height: h * 1.6),
                                           transform: nil))
        }
        return path
    }

    private static func stroke(_ ctx: CGContext, _ path: CGPath, _ col: CGColor, _ width: Double) {
        ctx.addPath(path)
        ctx.setStrokeColor(col)
        // Qt draws width 0 as a one-pixel (cosmetic) line
        ctx.setLineWidth(CGFloat(width > 0 ? width : 1 / max(abs(ctx.ctm.a), 1e-6)))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// Soft halo: stacked faint strokes, widest first, so alpha builds toward the shape. Not antialiased on
    /// purpose: ~5 % layers have no visible edge, so antialiasing them is pure cost (about 4x at idle).
    static func glow(_ ctx: CGContext, _ path: CGPath, _ p: FaceParams, base: Double = 0) {
        ctx.setShouldAntialias(false)
        for i in 0..<7 { stroke(ctx, path, colour(p, 0.045 * (0.3 + p.glow)), base + 30 - 4 * Double(i)) }
        ctx.setShouldAntialias(true)
    }

    private static func glowFill(_ ctx: CGContext, _ path: CGPath, _ p: FaceParams) {
        glow(ctx, path, p)
        ctx.addPath(path)
        ctx.setStrokeColor(colour(p))  // same-colour stroke softens lid corners
        ctx.setFillColor(colour(p))
        ctx.setLineWidth(5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
    }

    private static func mouth(_ ctx: CGContext, _ p: FaceParams, oy: Double) {
        let w = mouthW * p.mouthW
        let cx = W / 2, cy = mouthY + oy
        let bend = 14 * max(-1.0, min(1.0, p.mouthCurve))
        let path = CGMutablePath()
        path.move(to: pt(cx - w / 2, cy - bend / 2))
        path.addQuadCurve(to: pt(cx + w / 2, cy - bend / 2), control: pt(cx, cy + bend * 1.5))
        let opening = 26 * clamp(p.mouthOpen)
        let fill = opening > 1.5
        if fill {
            path.addQuadCurve(to: pt(cx - w / 2, cy - bend / 2), control: pt(cx, cy + bend * 1.5 + opening * 2))
            path.closeSubpath()
        }
        glow(ctx, path, p, base: -6)
        ctx.addPath(path)
        ctx.setStrokeColor(colour(p))
        ctx.setLineWidth(5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if fill {
            ctx.setFillColor(colour(p, 0.9, value: 0.85))
            ctx.drawPath(using: .fillStroke)
        } else {
            ctx.strokePath()
        }
    }

    private static func blob(_ ctx: CGContext, _ c: CGPoint, _ rx: Double, _ ry: Double, _ col: CGColor) {
        let edge = col.copy(alpha: 0)!
        let g = CGGradient(colorsSpace: srgb, colors: [col, edge] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
        ctx.clip()
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(rx, ry), options: [])
        ctx.restoreGState()
    }

    /// Bold system-font text with its baseline at `at`.
    private static func text(_ ctx: CGContext, _ at: CGPoint, _ s: String, _ size: Double, _ col: CGColor) {
        let font = NSFont.boldSystemFont(ofSize: CGFloat(size))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): col,
        ]))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // the canvas is y-down
        ctx.textPosition = at
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func effects(_ ctx: CGContext, _ p: FaceParams, t: Double, oy: Double) {
        let fx = p.effects, accent = colour(p)
        if fx.contains("blush") || fx.contains("sparkle") {
            for side in [-1.0, 1.0] {
                blob(ctx, pt(W / 2 + side * (eyeX + 18), eyeY + 50 + oy), 20, 10,
                     rgb(RGBA(r: 255, g: 110, b: 150, a: 120)))
            }
        }
        if fx.contains("sweat") {
            let x = W / 2 + eyeX + 46, y = eyeY - 30 + oy + 3 * sin(t * 3)
            let drop = CGMutablePath()
            drop.move(to: pt(x, y - 13))
            drop.addCurve(to: pt(x + 8, y + 4), control1: pt(x + 2, y - 6), control2: pt(x + 8, y))
            arc(drop, in: CGRect(x: x - 8, y: y - 4, width: 16, height: 16), from: 0, sweep: .pi)  // through the bottom
            drop.addCurve(to: pt(x, y - 13), control1: pt(x - 8, y), control2: pt(x - 2, y - 6))
            ctx.addPath(drop)
            ctx.setFillColor(rgb(RGBA(r: 130, g: 200, b: 255, a: 220)))
            ctx.fillPath()
        }
        if fx.contains("question") {
            text(ctx, pt(W / 2 + eyeX + 34, eyeY - 38 + oy + 3 * sin(t * 2)), "?", 26, accent)
        }
        if fx.contains("zzz") {
            for i in 0..<3 {
                let k = (t * 0.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                text(ctx, pt(W / 2 + 70 + 22 * k + 6 * Double(i), 70 - 45 * k), "z", 10 + 8 * k,
                     colour(p, sin(Double.pi * k) * 0.9))
            }
        }
        if fx.contains("dots") {
            for i in 0..<3 {
                let a = 0.25 + 0.75 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 1.1))
                blob(ctx, pt(W / 2 + eyeX + 34 + Double(i) * 14, 30 - Double(i) * 6 + oy), 6, 6, colour(p, a))
            }
        }
        if fx.contains("gear") {
            let c = pt(W / 2 + eyeX + 52, 36 + oy)
            for i in 0..<8 {
                let ang = t * 4 + Double(i) * Double.pi / 4
                ctx.setFillColor(colour(p, 0.15 + 0.85 * (Double(i) / 7)))
                ctx.fillEllipse(in: CGRect(x: c.x + 11 * cos(ang) - 2.6, y: c.y + 11 * sin(ang) - 2.6,
                                           width: 5.2, height: 5.2))
            }
        }
        if fx.contains("pulse") {
            for i in 0..<2 {
                let k = (t * 0.8 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                for side in [-1.0, 1.0] {
                    let rr = 18 + 22 * k, cx = W / 2 + side * (eyeX + eyeW / 2 + 6)
                    let box = CGRect(x: cx - rr, y: eyeY + oy - rr, width: 2 * rr, height: 2 * rr)
                    let half = 35 * Double.pi / 180  // an arc of 70 degrees centred on the eye's outer side
                    let arcPath = CGMutablePath()
                    let from = (side > 0 ? 0 : Double.pi) - half
                    arcPath.move(to: pt(box.midX + rr * cos(from), box.midY + rr * sin(from)))
                    arc(arcPath, in: box, from: from, sweep: 2 * half)
                    stroke(ctx, arcPath, colour(p, 0.6 * (1 - k)), 3)
                }
            }
        }
        if fx.contains("sparkle") {
            for (i, (x, y, s0)) in [(W / 2 - eyeX - 48, 52.0, 9.0), (W / 2 + eyeX + 50, 44.0, 12.0)].enumerated() {
                let s = s0 * (0.75 + 0.25 * sin(t * 4 + Double(i) * 2))
                let star = CGMutablePath()
                star.move(to: pt(x, y - s))
                for (end) in [pt(x + s, y), pt(x, y + s), pt(x - s, y), pt(x, y - s)] {
                    star.addQuadCurve(to: end, control: pt(x, y))
                }
                ctx.addPath(star)
                ctx.setFillColor(rgb(RGBA(r: 255, g: 236, b: 170, a: 230)))
                ctx.fillPath()
            }
        }
    }

    /// Paint face `p` into `rect` (aspect kept, centred). `t` drives the effect animation; `bg` is the
    /// screen's (centre, edge) colours, default the dark blue the face always had.
    static func render(_ ctx: CGContext, rect: CGRect, params p: FaceParams, t: Double = 0, bg: (RGBA, RGBA)? = nil) {
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        let (centre, edge) = bg ?? (screen, FaceRender.bg)
        let g = CGGradient(colorsSpace: srgb, colors: [rgb(centre), rgb(edge)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                               endCenter: CGPoint(x: rect.midX, y: rect.midY),
                               endRadius: max(rect.width, rect.height) * 0.7,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        let k = min(rect.width / W, rect.height / H)
        ctx.translateBy(x: rect.midX - W * k / 2, y: rect.midY - H * k / 2)
        ctx.scaleBy(x: k, y: k)
        let oy = 3 * p.bob, ox = 26 * p.gazeX, gy = 20 * p.gazeY
        for side in [-1.0, 1.0] { glowFill(ctx, eye(p, side: side, ox: ox, oy: gy + oy), p) }
        mouth(ctx, p, oy: oy + 0.4 * gy)
        effects(ctx, p, t: t, oy: oy)
        ctx.restoreGState()
    }
}
