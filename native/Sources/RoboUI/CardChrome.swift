// Everything the card paints: the frame (glow, glass, aura, scanlines, grid, sheen, header tint, divider,
// border, brackets, tail dot), the header with its lights and model chip, the quote's bar, the caret, the
// typing dots, buttons, the theme swatches. Port of src/robo/hud.py and the painting half of widgets.py.
// Every colour comes from a `Theme` token (`Themes.rgba`, `accent`, `labelColour`), never a literal. The
// views are y-down (isFlipped) so the Python coordinates carry over unchanged.
import AppKit
import RoboCore

extension RGBA {
    var ns: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255) }
}

/// Metrics and drawing shared by the card's views.
enum Chrome {
    static let glow: CGFloat = 6  // px of margin around the frame that the glow may use
    static let headerH: CGFloat = 26
    static let tailW: CGFloat = 20, tailH: CGFloat = 9
    /// The card's single column: 6 glow + 13 padding at the sides, 6 + 26 header + 10 on top, 9 tail + 10 below.
    static let margins = NSEdgeInsets(top: 42, left: 19, bottom: 19, right: 19)
    static let spacing: CGFloat = 8
    static let bar: CGFloat = 2, wash: CGFloat = 5  // the quote's accent bar and the tinted strip it sits on

    static func color(_ hex: String, _ alpha: Double = 1) -> NSColor { Themes.rgba(hex, alpha: alpha).ns }
    static func accent(_ t: Theme, _ hue: Double, _ alpha: Double = 1) -> NSColor { Themes.accent(t, hue, alpha: alpha).ns }

    /// The hue in the 2 degree steps the card follows the face in (Python `round` is half to even).
    static func quantised(_ hue: Double) -> Double {
        let q = ((hue / 2).rounded(.toNearestOrEven) * 2).truncatingRemainder(dividingBy: 360)
        return q < 0 ? q + 360 : q
    }

    // MARK: fonts

    static let monoFamily: String = {
        let have = Set(NSFontManager.shared.availableFontFamilies)
        return ["SF Mono", "Menlo", "DejaVu Sans Mono"].first(where: have.contains) ?? "Menlo"
    }()

    static func mono(_ px: CGFloat, bold: Bool = false) -> NSFont {
        let regular = NSFont(name: monoFamily, size: px) ?? .monospacedSystemFont(ofSize: px, weight: .regular)
        return bold ? NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask) : regular
    }

    /// Qt's integer font metrics (ascent and descent each rounded), which the Python layout is built on.
    static func metrics(_ font: NSFont) -> (ascent: CGFloat, descent: CGFloat) { (font.ascender.rounded(), (-font.descender).rounded()) }

    /// The letter spacing that gives the system font the advances Qt measures for it (Qt uses the font's plain advances, AppKit
    /// applies SF's optical tracking, which differs by size): fitted to Qt's widths of four sentences at 12-18 px.
    static func qtKern(_ px: CGFloat) -> CGFloat {
        let table: [(CGFloat, CGFloat)] = [(12, 0.19), (13, 0.125), (14, 0.08), (16, -0.05), (18, -0.22)]
        if px <= table[0].0 { return table[0].1 }
        for (a, b) in zip(table, table.dropFirst()) where px <= b.0 { return a.1 + (b.1 - a.1) * (px - a.0) / (b.0 - a.0) }
        return table.last!.1
    }

    /// The height Qt's text layout gives a line of this font: ascent, descent and leading, rounded up.
    static func qtLine(_ font: NSFont) -> CGFloat { (font.ascender - font.descender + font.leading).rounded(.up) }

    static func attrs(_ font: NSFont, _ colour: NSColor, kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: colour, .kern: kern]
    }

    /// Qt's `horizontalAdvance`: the text's width, whole pixels.
    static func advance(_ s: String, _ font: NSFont, kern: CGFloat = 0) -> CGFloat {
        NSAttributedString(string: s, attributes: attrs(font, .black, kern: kern)).size().width.rounded()
    }

    /// Draw one line vertically centred in a box of height `h` whose top is at `y`, left edge at `x`.
    static func line(_ s: String, _ font: NSFont, _ colour: NSColor, kern: CGFloat = 0, x: CGFloat, y: CGFloat, h: CGFloat) {
        let m = metrics(font)
        let baseline = y + ((h - (m.ascent + m.descent)) / 2) + m.ascent + 0.5  // Qt's text sits half a pixel lower (measured against its pixels)
        NSAttributedString(string: s, attributes: attrs(font, colour, kern: kern)).draw(at: NSPoint(x: x, y: baseline - font.ascender))
    }

    // MARK: arcs and the outline

    /// Qt's `arcTo`: angles are counter-clockwise on the screen from 3 o'clock; the context is y-down.
    private static func arc(_ p: CGMutablePath, _ r: CGRect, _ start: Double, _ sweep: Double) {
        let c = CGPoint(x: r.midX, y: r.midY)
        p.addArc(center: c, radius: r.width / 2, startAngle: -start * .pi / 180, endAngle: -(start + sweep) * .pi / 180, clockwise: sweep > 0)
    }

    static func corner(_ t: Theme, _ r: CGRect) -> CGFloat { max(0, min(CGFloat(t.corner), min(r.width, r.height) / 2 - 1)) }

    /// The frame: chamfered or rounded corners, and the tail notch in the bottom edge.
    static func outline(_ r: CGRect, _ t: Theme, tailX: CGFloat) -> CGPath {
        let c = corner(t, r), x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY, hw = tailW / 2
        let tail = [CGPoint(x: tailX + hw, y: y1), CGPoint(x: tailX, y: y1 + tailH), CGPoint(x: tailX - hw, y: y1)]
        let p = CGMutablePath()
        if t.shape == "round" && c > 0 {
            p.move(to: CGPoint(x: x0 + c, y: y0))
            p.addLine(to: CGPoint(x: x1 - c, y: y0))
            arc(p, CGRect(x: x1 - 2 * c, y: y0, width: 2 * c, height: 2 * c), 90, -90)
            p.addLine(to: CGPoint(x: x1, y: y1 - c))
            arc(p, CGRect(x: x1 - 2 * c, y: y1 - 2 * c, width: 2 * c, height: 2 * c), 0, -90)
            for pt in tail + [CGPoint(x: x0 + c, y: y1)] { p.addLine(to: pt) }
            arc(p, CGRect(x: x0, y: y1 - 2 * c, width: 2 * c, height: 2 * c), 270, -90)
            p.addLine(to: CGPoint(x: x0, y: y0 + c))
            arc(p, CGRect(x: x0, y: y0, width: 2 * c, height: 2 * c), 180, -90)
        } else {
            let pts = [CGPoint(x: x0 + c, y: y0), CGPoint(x: x1 - c, y: y0), CGPoint(x: x1, y: y0 + c), CGPoint(x: x1, y: y1 - c),
                       CGPoint(x: x1 - c, y: y1)] + tail + [CGPoint(x: x0 + c, y: y1), CGPoint(x: x0, y: y1 - c), CGPoint(x: x0, y: y0 + c)]
            p.move(to: pts[0])
            for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    /// One of the four corner brackets ("tl", "tr", "br", "bl"): an arm of `brLen` each way that follows the corner.
    static func bracket(_ corner: String, _ r: CGRect, _ t: Theme) -> CGPath {
        let c = Self.corner(t, r), x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        let n = max(CGFloat(t.brLen), c)  // an arm shorter than the chamfer would fold back on itself
        let round = t.shape == "round" && c > 0
        let p = CGMutablePath()
        switch corner {
        case "tl":
            p.move(to: CGPoint(x: x0, y: y0 + n)); p.addLine(to: CGPoint(x: x0, y: y0 + c))
            if round { arc(p, CGRect(x: x0, y: y0, width: 2 * c, height: 2 * c), 180, -90) } else { p.addLine(to: CGPoint(x: x0 + c, y: y0)) }
            p.addLine(to: CGPoint(x: x0 + n, y: y0))
        case "tr":
            p.move(to: CGPoint(x: x1 - n, y: y0)); p.addLine(to: CGPoint(x: x1 - c, y: y0))
            if round { arc(p, CGRect(x: x1 - 2 * c, y: y0, width: 2 * c, height: 2 * c), 90, -90) } else { p.addLine(to: CGPoint(x: x1, y: y0 + c)) }
            p.addLine(to: CGPoint(x: x1, y: y0 + n))
        case "br":
            p.move(to: CGPoint(x: x1, y: y1 - n)); p.addLine(to: CGPoint(x: x1, y: y1 - c))
            if round { arc(p, CGRect(x: x1 - 2 * c, y: y1 - 2 * c, width: 2 * c, height: 2 * c), 0, -90) } else { p.addLine(to: CGPoint(x: x1 - c, y: y1)) }
            p.addLine(to: CGPoint(x: x1 - n, y: y1))
        default:
            p.move(to: CGPoint(x: x0 + n, y: y1)); p.addLine(to: CGPoint(x: x0 + c, y: y1))
            if round { arc(p, CGRect(x: x0, y: y1 - 2 * c, width: 2 * c, height: 2 * c), 270, -90) } else { p.addLine(to: CGPoint(x: x0, y: y1 - c)) }
            p.addLine(to: CGPoint(x: x0, y: y1 - n))
        }
        return p
    }

    // MARK: the frame

    private static func gradient(_ stops: [(Double, RGBA)]) -> CGGradient {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGGradient(colorsSpace: space, colors: stops.map { $0.1.ns.cgColor } as CFArray, locations: stops.map { CGFloat($0.0) })!
    }

    /// The card's frame and surface at `size` (logical px) and pixel ratio `dpr`: glow, glass fill, aura, scanlines,
    /// grid, sheen, header tint and divider, border, corner brackets, tail dot. Transparent where nothing is
    /// painted; the text goes on top. The card caches it (`CardView.frame(for:)`).
    static func frame(_ t: Theme, size: CGSize, dpr: CGFloat, hue: Double) -> CGImage? {
        func acc(_ alpha: Double = 1, _ dh: Double = 0) -> RGBA { Themes.accent(t, hue + dh, alpha: alpha) }
        let w = size.width, h = size.height
        guard let g = CGContext(data: nil, width: Int((w * dpr).rounded()), height: Int((h * dpr).rounded()), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        g.scaleBy(x: dpr, y: -dpr)  // y-down, like Qt
        g.translateBy(x: 0, y: -h)
        let body = CGRect(x: glow + 0.5, y: glow + 0.5, width: w - 2 * glow - 1, height: h - glow - tailH - 1)
        let path = outline(body, t, tailX: w / 2)
        if t.glow > 0 {  // halo: faint strokes, widest first, so alpha builds toward the frame; ~5 % layers: no visible edge
            g.setShouldAntialias(false)
            for (i, width) in [9.0, 7, 5, 3].enumerated() {
                g.setStrokeColor(acc(t.glow * 0.035 * Double(i + 1)).ns.cgColor)
                g.setLineWidth(width); g.setLineJoin(.round)
                g.addPath(path); g.strokePath()
            }
            g.setShouldAntialias(true)
        }
        func fill(_ draw: () -> Void) { g.saveGState(); g.addPath(path); g.clip(); draw(); g.restoreGState() }
        let alpha = max(t.bgA, 0.90)  // the window cannot blur the wallpaper: stay mostly opaque
        fill {
            g.drawLinearGradient(gradient([(0, Themes.rgba(t.bgTop, alpha: alpha)), (1, Themes.rgba(t.bgBot, alpha: alpha))]),
                                 start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let dh = Themes.auraShift(t, hue)
        if t.aura > 0 {  // a bloom in the top right corner, shifted toward pink
            fill {
                g.drawRadialGradient(gradient([(0, acc(t.aura, dh)), (1, acc(0, dh))]), startCenter: CGPoint(x: body.maxX - 20, y: body.minY + 6), startRadius: 0,
                                     endCenter: CGPoint(x: body.maxX - 20, y: body.minY + 6), endRadius: 190, options: [])
            }
        }
        if t.scanA > 0 {
            fill {
                g.setFillColor(Themes.rgba(t.scanC, alpha: t.scanA).ns.cgColor)
                for y in stride(from: 0, to: Int(h), by: t.scanPx) { g.fill(CGRect(x: 0, y: CGFloat(y), width: w, height: 1)) }
            }
        }
        if t.gridA > 0 {
            fill {
                g.setFillColor(acc(t.gridA).ns.cgColor)
                for x in stride(from: 6, to: Int(w), by: 14) { for y in stride(from: 6, to: Int(h), by: 14) { g.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)) } }
            }
        }
        if t.sheen > 0 {  // gloss over the top half
            fill {
                g.drawLinearGradient(gradient([(0, RGBA(r: 255, g: 255, b: 255, a: UInt8((255 * t.sheen).rounded(.toNearestOrEven)))), (1, RGBA(r: 255, g: 255, b: 255, a: 0))]),
                                     start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.minY + body.height * 0.5), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        fill {  // header tint
            g.setFillColor(acc(0.07).ns.cgColor)
            g.fill(CGRect(x: body.minX, y: body.minY, width: body.width, height: headerH))
        }
        let y = body.minY + headerH  // divider, and a bright tick under the diamond
        g.saveGState()
        g.clip(to: CGRect(x: body.minX + 1, y: y - 0.5, width: body.width - 2, height: 1))
        g.drawLinearGradient(gradient([(0, acc(0.55)), (0.65, acc(0.10)), (1, acc(0.04))]), start: CGPoint(x: body.minX, y: 0), end: CGPoint(x: body.maxX, y: 0),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        g.restoreGState()
        g.setFillColor(acc(0.95).ns.cgColor)
        g.fill(CGRect(x: body.minX + 13, y: y - 0.8, width: 27, height: 1.6))
        g.setLineWidth(1)  // the border; the stroke drifts toward pink from the top left to the bottom right
        if t.auraDh > 0 {
            g.saveGState(); g.addPath(path); g.replacePathWithStrokedPath(); g.clip()
            g.drawLinearGradient(gradient([(0, acc(t.borderA)), (1, acc(t.borderA, dh))]), start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY),
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            g.restoreGState()
        } else {
            g.setStrokeColor(acc(t.borderA).ns.cgColor); g.addPath(path); g.strokePath()
        }
        if t.brLen > 0 {
            for corner in ["tl", "tr", "br", "bl"] {  // brighter and thicker than the border
                for (width, a) in [(t.brW + 4, 0.12), (t.brW, 1.0)] {
                    g.setStrokeColor(acc(a).ns.cgColor); g.setLineWidth(width); g.setLineCap(.butt); g.setLineJoin(.miter)
                    g.addPath(bracket(corner, body, t)); g.strokePath()
                }
            }
        }
        g.setFillColor(acc(1).ns.cgColor)  // the tail's tip: a small bright dot
        g.fillEllipse(in: CGRect(x: w / 2 - 1.5, y: body.maxY + tailH - 3, width: 3, height: 3))
        return g.makeImage()
    }
}

/// How the label of a `Led` reads; the dot's colour AND the label change with the state (hud.LED_STATES).
extension LedState {
    var suffix: String { [.warn: " …", .loading: " …", .bad: " ✕", .off: " OFF"][self] ?? "" }
}

/// Ink for a small label: "lab" is the accent's paler label colour, "warn" the warning light, "dim" the quiet text.
enum Tone { case lab, warn, dim }

/// Tiny monospace text painted in the live accent hue: "YOU ▸", "APPROVAL ▸", the status line.
final class MicroLabel: NSView {
    var text: String { didSet { if text != oldValue { needsDisplay = true } } }
    var theme: Theme { didSet { needsDisplay = true } }
    var hue: Double { didSet { needsDisplay = true } }
    let tone: Tone, px: CGFloat, spacing: CGFloat, bold: Bool

    init(_ text: String = "", theme: Theme, px: CGFloat = 9, spacing: CGFloat = 1.4, bold: Bool = true, tone: Tone = .lab) {
        (self.text, self.theme, self.hue, self.tone, self.px, self.spacing, self.bold) = (text, theme, theme.hue, tone, px, spacing, bold)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    var font: NSFont { Chrome.mono(px, bold: bold) }
    /// QLabel's own hint ignores the letter spacing, so it is measured here.
    var fitting: NSSize { NSSize(width: Chrome.advance(text, font, kern: spacing) + 2, height: Chrome.metrics(font).ascent + Chrome.metrics(font).descent + 2) }

    override func draw(_ dirtyRect: NSRect) {
        let ink: NSColor
        switch tone {
        case .lab: ink = Themes.labelColour(theme, hue).ns
        case .warn: ink = Chrome.color(theme.ledWarn)
        case .dim: ink = Chrome.color(theme.textDim)
        }
        Chrome.line(text, font, ink, kern: spacing, x: 0, y: 0, h: bounds.height)
    }
}

/// A status light with a word (the label never relies on colour alone). `blink` states flash at 1 Hz and "hot"
/// pulses, both driven by the phase the app hands to `setPhase`.
struct Led {
    let name: String, hot: String?
    private(set) var state = LedState.unknown
    private(set) var lit = true, pulse = 1.0
    static let font = Chrome.mono(8, bold: true)

    init(_ name: String, hot: String? = nil, state: LedState = .unknown) { self.name = name; self.hot = hot; self.state = state }

    var label: String { state == .hot && hot != nil ? hot! : name + state.suffix }
    var width: CGFloat { 14 + Chrome.advance(label, Led.font, kern: 1) + 2 }
    var motion: String { [.warn: "blink", .loading: "blink", .hot: "pulse"][state] ?? "" }

    mutating func set(_ s: LedState) { state = s }

    /// The clock for blinking and pulsing; false when what is drawn did not change.
    mutating func setPhase(_ t: Double) -> Bool {
        let lit = motion != "blink" || Int(t * 2) % 2 == 0
        let pulse = motion == "pulse" ? ((0.5 + 0.5 * sin(t * 2 * .pi * 0.8)) * 10).rounded(.toNearestOrEven) / 10 : 1.0
        if (lit, pulse) == (self.lit, self.pulse) { return false }
        (self.lit, self.pulse) = (lit, pulse)
        return true
    }

    func draw(in box: CGRect, _ t: Theme, hue: Double) {
        let c = CGPoint(x: box.minX + 7, y: box.midY)
        let ring = state == .unknown || state == .off
        let dim = Themes.rgba(t.textDim)
        if ring {  // unknown / off: an empty ring
            dim.ns.setStroke()
            let p = NSBezierPath(ovalIn: CGRect(x: c.x - 2.4, y: c.y - 2.4, width: 4.8, height: 4.8)); p.lineWidth = 1.2; p.stroke()
        } else if !lit {  // the dark half of a blink
            Themes.rgba(t.textDim, alpha: 0.35).ns.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 2.7, y: c.y - 2.7, width: 5.4, height: 5.4)).fill()
        } else {
            let dot: RGBA
            switch state {
            case .ok: dot = Themes.rgba(t.ledOk)
            case .warn, .loading: dot = Themes.rgba(t.ledWarn)
            case .bad: dot = Themes.rgba(t.ledBad)
            default: dot = Themes.accent(t, hue)
            }
            let strength = motion == "pulse" ? 60 + 120 * pulse : 110
            let halo = NSGradient(colors: [RGBA(r: dot.r, g: dot.g, b: dot.b, a: UInt8(strength.rounded())).ns, RGBA(r: dot.r, g: dot.g, b: dot.b, a: 0).ns])!
            halo.draw(fromCenter: c, radius: 0, toCenter: c, radius: 7, options: [])
            dot.ns.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 2.7, y: c.y - 2.7, width: 5.4, height: 5.4)).fill()
        }
        Chrome.line(label, Led.font, dim.ns, kern: 1, x: box.minX + 14, y: box.minY, h: box.height)
    }
}

/// The strip at the top of the frame: diamond, the bot's name, a Hermes and a microphone light, the model chip
/// on the right. When too narrow the chip goes first (under 40 px it is hidden); the lights and the name keep
/// their room. The card puts it at (6, 6) of the frame.
final class HeaderView: NSView {
    var theme: Theme { didSet { place(); needsDisplay = true } }
    var hue: Double { didSet { needsDisplay = true } }
    var model: String { didSet { place() } }  // the configured model (`model.default`), for the chip when the theme names none
    private(set) var link = Led("HERMES"), mic = Led("MIC", hot: "LISTENING", state: .off)
    /// Where the model chip is drawn (nil: hidden), and its text.
    private(set) var chip: CGRect?
    private(set) var chipText = ""
    /// Where each light starts (the dot's slot is 3 px to its right).
    private(set) var linkX: CGFloat = 0, micX: CGFloat = 0
    private static let chipFont = Chrome.mono(9), nameFont = Chrome.mono(11, bold: true)

    init(theme: Theme, model: String) {
        (self.theme, self.hue, self.model) = (theme, theme.hue, model)
        super.init(frame: NSRect(x: 0, y: 0, width: CardView.width - 2 * Chrome.glow, height: Chrome.headerH))
        place()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); place() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setStatus(link: LedState, mic: LedState) {
        guard link != self.link.state || mic != self.mic.state else { return }
        self.link.set(link); self.mic.set(mic)
        place(); needsDisplay = true
    }

    func setPhase(_ t: Double) {
        let a = link.setPhase(t), b = mic.setPhase(t)
        if a || b { needsDisplay = true }
    }

    /// The bot's name as the header spells it.
    var displayName: String { theme.botName.uppercased() }

    private func place() {
        var x = 25 + Chrome.advance(displayName, Self.nameFont, kern: 2.4) + 14
        linkX = x - 3; x += link.width + 6  // 3 px left of the dot's slot: the halo needs room
        micX = x - 3; x += mic.width + 6
        let text = Themes.chipText(theme, configuredModel: model)
        let room = bounds.width - 12 - x  // the chip's whole width (text plus 7 px padding each side)
        let shown = Self.elided(text, to: max(0, room - 14))
        let width = Chrome.advance(shown, Self.chipFont, kern: 0.3) + 14
        chipText = shown
        chip = text.isEmpty || width < 40 ? nil : CGRect(x: bounds.width - 12 - width, y: ((Chrome.headerH - 17) / 2).rounded(.down), width: width, height: 17)
        needsDisplay = true
    }

    private static func elided(_ s: String, to limit: CGFloat) -> String {
        if Chrome.advance(s, chipFont, kern: 0.3) <= limit { return s }
        var t = Array(s)
        while !t.isEmpty && Chrome.advance(String(t) + "…", chipFont, kern: 0.3) > limit { t.removeLast() }
        return String(t) + "…"
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme, h = Chrome.headerH
        NSGraphicsContext.saveGraphicsState()  // the diamond: a halo square and a solid one, turned 45 degrees
        let move = NSAffineTransform(); move.translateX(by: 14, yBy: h / 2); move.rotate(byDegrees: 45); move.concat()
        Chrome.accent(t, hue, 0.25).setFill(); NSRect(x: -5, y: -5, width: 10, height: 10).fill()
        Chrome.accent(t, hue).setFill(); NSRect(x: -3, y: -3, width: 6, height: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        Chrome.line(displayName, Self.nameFont, Themes.labelColour(t, hue).ns, kern: 2.4, x: 25, y: 0, h: h)  // the accent itself is under 4.5:1 on blues
        link.draw(in: CGRect(x: linkX, y: 0, width: link.width, height: h), t, hue: hue)
        mic.draw(in: CGRect(x: micX, y: 0, width: mic.width, height: h), t, hue: hue)
        if let chip {
            Chrome.accent(t, hue, 0.07).setFill(); Chrome.accent(t, hue, 0.38).setStroke()
            let r = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: CGFloat(t.radius), yRadius: CGFloat(t.radius))
            r.fill(); r.lineWidth = 1; r.stroke()
            let w = Chrome.advance(chipText, Self.chipFont, kern: 0.3)
            Chrome.line(chipText, Self.chipFont, Chrome.color(t.textDim), kern: 0.3, x: chip.minX + ((chip.width - w) / 2).rounded(.down), y: chip.minY, h: chip.height)
        }
    }
}

/// The accent bar, the wash behind it and the hairline under the text of the user's quote.
final class QuoteView: NSView {
    var theme: Theme { didSet { needsDisplay = true } }
    var hue: Double { didSet { needsDisplay = true } }
    init(theme: Theme) { (self.theme, self.hue) = (theme, theme.hue); super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme, h = bounds.height, w = bounds.width
        Chrome.accent(t, hue, 0.10).setFill(); NSRect(x: 0, y: 1, width: Chrome.wash, height: h - 2 - 7).fill()
        NSGradient(colors: [Chrome.accent(t, hue), Chrome.accent(t, hue, 0.30)])!.draw(in: NSRect(x: 0, y: 1, width: Chrome.bar, height: h - 2 - 7), angle: 90)
        NSGradient(colors: [Chrome.accent(t, hue, 0.26), Chrome.accent(t, hue, 0)])!.draw(in: NSRect(x: 11, y: h - 1, width: w - 11, height: 1), angle: 0)  // between the question and the answer
    }
}

/// The typing caret: a block, a bar or an underline in the accent colour, with a 1 px halo. A child of the reply's
/// viewport in Python (never part of the document); the card keeps it over the reply and calls `place`.
final class CaretView: NSView {
    var theme: Theme { didSet { needsDisplay = true } }
    var hue: Double { didSet { needsDisplay = true } }
    private(set) var on = true
    init(theme: Theme) { (self.theme, self.hue) = (theme, theme.hue); super.init(frame: .zero); isHidden = true }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // WA_TransparentForMouseEvents

    func setOn(_ on: Bool) { if on != self.on { self.on = on; needsDisplay = true } }

    /// The caret's box (a 1 px halo included) for the text cursor's rectangle `line` in viewport coordinates of a
    /// viewport of `size`: 0.58 x 1.18 times the text size, centred on the line, always inside the viewport.
    static func box(for line: CGRect, theme: Theme, in size: CGSize) -> CGRect {
        let px = CGFloat(theme.textPx)
        let w = max(8, (px * 0.58).rounded(.toNearestOrEven)), h = max(10, (px * 1.18).rounded(.toNearestOrEven))
        let x = min(max(2, line.minX.rounded(.down) + 1), max(2, size.width - w - 2))
        let y = min(max(2, line.minY.rounded(.down) + ((line.height - h) / 2).rounded(.down) + 1), max(2, size.height - h - 2))
        return CGRect(x: x - 1, y: y - 1, width: w + 2, height: h + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard on else { return }
        let r = bounds, core = r.insetBy(dx: 1, dy: 1)
        Chrome.accent(theme, hue, 0.18).setFill(); r.fill()  // the halo
        Chrome.accent(theme, hue, 0.95).setFill()
        switch theme.caret {
        case "bar": NSRect(x: core.minX, y: core.minY, width: 2, height: core.height).fill()
        case "under": NSRect(x: core.minX, y: core.maxY - 2, width: core.width, height: 2).fill()
        default: core.fill()
        }
    }
}

/// Messenger-style "typing" dots: three dots in the accent colour that hop in turn while robo thinks. The view owns
/// a 33 ms timer only while it is shown.
final class TypingDotsView: NSView {
    static let hop: CGFloat = 4
    var theme: Theme { didSet { needsDisplay = true } }
    var hue: Double { didSet { needsDisplay = true } }
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private(set) var timer: Timer?

    init(theme: Theme) { (self.theme, self.hue) = (theme, theme.hue); super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 16)) }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { timer?.invalidate() }
    override var isFlipped: Bool { true }

    /// Vertical offset of each dot at time `t` (a wave running left to right, 1.2 s).
    static func offsets(_ t: Double) -> [CGFloat] { (0..<3).map { -hop * CGFloat(max(0, sin((t / 1.2 - Double($0) * 0.15) * 2 * .pi))) } }

    private func sync() {
        let shown = window != nil && !isHiddenOrHasHiddenAncestor
        if shown && timer == nil {
            let tick = Timer(timeInterval: 0.033, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            RunLoop.main.add(tick, forMode: .common)
            timer = tick
        } else if !shown {
            timer?.invalidate(); timer = nil
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); sync() }
    override func viewDidHide() { super.viewDidHide(); sync() }
    override func viewDidUnhide() { super.viewDidUnhide(); sync() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); sync() }

    override func draw(_ dirtyRect: NSRect) {
        for (i, dy) in Self.offsets(clock()).enumerated() {
            Chrome.accent(theme, hue, 0.55 + 0.45 * Double(-dy / Self.hop)).setFill()
            NSBezierPath(ovalIn: CGRect(x: 5 + 11 * CGFloat(i) - 2.8, y: 10 + dy - 2.8, width: 5.6, height: 5.6)).fill()
        }
    }
}

/// A button in the card's style sheet: the menu chips and Allow / Deny.
final class ButtonView: NSView {
    enum Kind { case plain, allow, deny }
    var title: String { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var kind: Kind { didSet { needsDisplay = true } }
    var theme: Theme { didSet { needsDisplay = true } }  // the style sheet uses the RESTING hue, so no live hue here
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(_ title: String, kind: Kind = .plain, theme: Theme) {
        (self.title, self.kind, self.theme) = (title, kind, theme)
        super.init(frame: .zero)
        setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme
        func a(_ alpha: Double) -> NSColor { Chrome.accent(t, t.hue, alpha) }
        var fill = a(0.08), edge = a(0.34), ink = Chrome.color(t.text), weight = NSFont.Weight.regular
        switch (kind, hovered) {
        case (.plain, true): fill = a(0.22); edge = a(0.85)
        case (.plain, false): break
        case (.allow, _):
            fill = hovered ? Themes.labelColour(t, t.hue).ns : a(1); edge = a(1); ink = Chrome.color(t.onAccent); weight = .semibold
        case (.deny, _):
            fill = hovered ? a(0.12) : .clear; edge = Themes.rgba(t.textDim, alpha: 0.45).ns
            ink = hovered ? Chrome.color(t.text) : Chrome.color(t.textDim)
        }
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: CGFloat(t.radius), yRadius: CGFloat(t.radius))
        fill.setFill(); r.fill(); edge.setStroke(); r.lineWidth = 1; r.stroke()
        let s = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: weight), .foregroundColor: ink, .kern: Chrome.qtKern(13)])
        let size = s.size()
        s.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(.down), y: ((bounds.height - size.height) / 2).rounded(.down)))
    }
}

/// A theme in the picker: a miniature card painted in that theme's OWN colours (resting hue), the current one ringed.
final class SwatchView: NSView {
    let theme: Theme
    var current = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(_ theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 54, height: 34))
        toolTip = theme.label
        setAccessibilityRole(.button); setAccessibilityLabel(theme.label)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme
        func acc(_ alpha: Double = 1) -> NSColor { Chrome.accent(t, t.hue, alpha) }
        let r = bounds.insetBy(dx: 2, dy: 2)
        let radius = t.shape == "round" ? min(CGFloat(t.corner), 7) : 2
        let card = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSGradient(colors: [Chrome.color(t.bgTop), Chrome.color(t.bgBot)])!.draw(in: card, angle: 90)
        acc(current ? 0.95 : 0.35).setStroke(); card.lineWidth = current ? 1.8 : 1; card.stroke()
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ colour: NSColor) {
            colour.setFill(); NSBezierPath(roundedRect: NSRect(x: r.minX + x, y: r.minY + y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        }
        bar(7, 7, 18, 3, acc()); bar(7, 14, 28, 2.5, Chrome.color(t.text)); bar(7, 19, 19, 2.5, Chrome.color(t.text))
        acc().setFill(); NSBezierPath(ovalIn: NSRect(x: r.maxX - 11, y: r.maxY - 10, width: 6, height: 6)).fill()
    }
}

/// A word-wrapped label of the style sheet: the footer (a hairline above, 6 px of padding) and the approval's well
/// (tinted, a warning-coloured bar at its left, rounded on the right).
final class WrapLabelView: NSView {
    enum Kind { case footer, well }
    let kind: Kind
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var theme: Theme { didSet { needsDisplay = true } }

    init(_ kind: Kind, theme: Theme) { (self.kind, self.theme) = (kind, theme); super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    private var font: NSFont { Chrome.mono(kind == .footer ? 11 : 11.5) }
    // QLabel puts half the width of an "x" in front of its text when it has a frame (a border in the style sheet)
    private var indent: CGFloat { (Chrome.advance("x", font) / 2).rounded(.down) }
    private var inset: NSEdgeInsets { kind == .footer ? NSEdgeInsets(top: 7, left: indent, bottom: 0, right: 0) : NSEdgeInsets(top: 6, left: 10 + indent, bottom: 6, right: 8) }
    private var ink: NSColor { Chrome.color(kind == .footer ? theme.textDim : theme.text) }

    /// The height the text needs at `width` (QLabel's height for width).
    func height(for width: CGFloat) -> CGFloat {
        let i = inset
        let box = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: NSSize(width: width - i.left - i.right, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return i.top + i.bottom + ceil(box.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme, i = inset
        if kind == .footer {
            Chrome.accent(t, t.hue, 0.22).setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            bounds.clip()
            let r = CGFloat(t.radius)
            Chrome.accent(t, t.hue, 0.07).setFill()
            NSBezierPath(roundedRect: NSRect(x: -r, y: 0, width: bounds.width + r, height: bounds.height), xRadius: r, yRadius: r).fill()
            NSGraphicsContext.restoreGraphicsState()
            Chrome.color(t.ledWarn).setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }
        NSAttributedString(string: text, attributes: Chrome.attrs(font, ink)).draw(
            with: NSRect(x: i.left, y: i.top, width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom), options: [.usesLineFragmentOrigin])
    }
}
