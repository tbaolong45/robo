// Everything the card draws apart from its text: the glass pane behind it, the header with its lights and model chip,
// the quote's bar, the caret, the typing dots and the buttons. The pane is the system's Liquid Glass
// (`NSGlassEffectView`, macOS 26; a frosted `NSVisualEffectView` before that), so the fill, the edge and the shadow
// are not painted here, and the text and the status lights use the system colours, which follow light and dark and
// stay legible over any wallpaper, until the card knows what is behind it: then it turns light over a dark backdrop and dark
// over a light one (`Shade`, `Chrome.ink`, `GlassSurface.setShade`) and the ink is ours. The other colour of our own is the
// accent the face's mood paints (`Themes.accent`):
// it tints the glass a little and colours the orb, the caret, the dots and the quote's bar. The views are y-down
// (isFlipped).
import AppKit
import RoboCore

extension RGBA {
    var ns: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255) }
}

/// Metrics and drawing shared by the card's views.
enum Chrome {
    static let glow: CGFloat = 6  // px of margin around the glass pane (room for the glass's own edge light)
    static let headerH: CGFloat = 26
    static let gap: CGFloat = 9  // between the pane and the face below it (there is no tail: the pane floats above the face)
    static let radius: CGFloat = 24  // the pane's corner radius
    /// The card's single column: 6 margin + 13 padding at the sides, 6 + 26 header + 10 on top, 9 gap + 10 below.
    static let margins = NSEdgeInsets(top: 42, left: 19, bottom: 19, right: 19)
    static let spacing: CGFloat = 8
    static let bar: CGFloat = 2, wash: CGFloat = 5  // the quote's accent bar and the tinted strip it sits on

    static func color(_ hex: String, _ alpha: Double = 1) -> NSColor { Themes.rgba(hex, alpha: alpha).ns }
    static func accent(_ t: Theme, _ hue: Double, _ alpha: Double = 1) -> NSColor { Themes.accent(t, hue, alpha: alpha).ns }

    /// How the card adapts to what is behind it (main thread only): 0 = light ink (a dark card), 1 = dark ink (a light card), in
    /// between while the card turns over. nil = not known (no Screen Recording, no look yet): the system's own colours below.
    static var ink: Double?

    /// The ink at `alpha`: near-white to near-black along `ink`, or the system's colour when nothing is known.
    private static func inked(_ alpha: CGFloat, system: NSColor) -> NSColor {
        guard let ink else { return system }
        return NSColor(white: 0.96 + (0.07 - 0.96) * ink, alpha: alpha)
    }

    /// The system's own colours (they resolve at draw time, so light, dark and the glass behind decide) until the card knows its
    /// backdrop, then the ink above with the alphas the system's have.
    static var text: NSColor { inked(1, system: .labelColor) }
    static var textDim: NSColor { inked(0.6, system: .secondaryLabelColor) }
    static var faint: NSColor { inked(0.3, system: .tertiaryLabelColor) }
    static var hairline: NSColor { inked(0.18, system: .separatorColor) }
    /// A quiet wash over glass: chips, code boxes.
    static func wash(_ alpha: CGFloat) -> NSColor { inked(alpha, system: NSColor.labelColor.withAlphaComponent(alpha)) }

    /// The hue in the 2 degree steps the card follows the face in (Python `round` is half to even).
    static func quantised(_ hue: Double) -> Double {
        let q = ((hue / 2).rounded(.toNearestOrEven) * 2).truncatingRemainder(dividingBy: 360)
        return q < 0 ? q + 360 : q
    }

    // MARK: fonts

    static func ui(_ px: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: px, weight: weight) }

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
}

/// The card's glass: `NSGlassEffectView` on macOS 26 and later, a frosted `NSVisualEffectView` before. Both are a
/// plain view behind the card's other views (not their parent), so the layout is the card's own.
///
/// It follows the system's light or dark until `setShade` gives it a level, then it is a light card, a dark card or a turn
/// between. A glass reads light or dark by its `appearance` (a tint barely moves that), so on macOS 26 there are two: the light
/// one below and the dark one above it fading out as the level rises. At rest only the one that shows is kept, since glass is
/// what costs the GPU.
final class GlassSurface: NSView {
    /// How strong the veil over the glass gets (white over a light card, black over a dark one; 0 = no veil): one number to tune
    /// the contrast of the card by eye. To drop the idea, delete `Veil`, this and the lines that name `veil`.
    static let veilStrength: CGFloat = 0.22  // measured 2026-10-19: text contrast 4.48:1 (dark card) and 8.8:1 (light card) at 0

    private let light: NSView  // the system's own look (appearance nil) until a shade is given
    private let dark: NSView?  // macOS 26 only
    private let veil = Veil()
    /// What `setShade` was given: nil = the system's look.
    private(set) var level: Double?

    override init(frame: NSRect) {
        if #available(macOS 26, *) {
            let below = NSGlassEffectView(), above = NSGlassEffectView()
            for glass in [below, above] {
                glass.style = .regular
                glass.cornerRadius = Chrome.radius
            }
            above.appearance = NSAppearance(named: .darkAqua)
            above.isHidden = true
            (light, dark) = (below, above)
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.state = .active  // the panel is never the key window: follow-the-window would leave it grey
            blur.blendingMode = .behindWindow
            blur.wantsLayer = true
            blur.layer?.cornerRadius = Chrome.radius
            blur.layer?.masksToBounds = true
            (light, dark) = (blur, nil)
        }
        super.init(frame: frame)
        addSubview(light)
        if let dark { addSubview(dark) }
        addSubview(veil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for v in [light, dark, veil] { v?.frame = bounds }
    }

    /// A light wash of the accent over the glass (macOS 26 only: the old blur has no tint).
    func tint(_ colour: NSColor) {
        if #available(macOS 26, *) {
            for case let glass as NSGlassEffectView in [light, dark] { glass.tintColor = colour }
        }
    }

    /// 0 = a dark card, 1 = a light card, between = the turn (the dark glass fades out over the light one); nil = the system's
    /// look, one glass.
    func setShade(_ level: Double?) {
        guard level != self.level else { return }
        self.level = level
        veil.set(level)
        guard let dark else {  // the one blur flips at the middle, no crossfade (and `popover` is the material that follows an appearance)
            light.appearance = level.flatMap { NSAppearance(named: $0 >= 0.5 ? .aqua : .darkAqua) }
            (light as? NSVisualEffectView)?.material = level == nil ? .hudWindow : .popover
            return
        }
        guard let level else {
            light.appearance = nil
            light.alphaValue = 1; light.isHidden = false
            dark.isHidden = true
            return
        }
        let l = min(max(level, 0), 1)
        if light.appearance?.name != .aqua { light.appearance = NSAppearance(named: .aqua) }
        light.isHidden = l == 0  // the dark glass covers it
        dark.alphaValue = 1 - l
        dark.isHidden = l == 1  // and the light one is all there is
    }

    /// A flat veil over the glass, to tune the card's contrast: white at `level` x strength and black at (1 - level) x strength.
    /// Hidden (and never drawn) while `veilStrength` is 0.
    private final class Veil: NSView {
        private var level = 0.0

        init() {
            super.init(frame: .zero)
            isHidden = true
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func set(_ level: Double?) {
            isHidden = GlassSurface.veilStrength == 0 || level == nil
            guard let level, level != self.level else { return }
            self.level = level
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds, xRadius: Chrome.radius, yRadius: Chrome.radius)
            NSColor.white.withAlphaComponent(level * GlassSurface.veilStrength).setFill(); shape.fill()
            NSColor.black.withAlphaComponent((1 - level) * GlassSurface.veilStrength).setFill(); shape.fill()
        }
    }
}

/// How the label of a `Led` reads; the dot's colour AND the label change with the state (hud.LED_STATES).
extension LedState {
    var suffix: String { [.warn: " …", .loading: " …", .bad: " ✕", .off: " OFF"][self] ?? "" }
}

/// Ink for a small label: the system's secondary label, the warning orange, or the quieter tertiary one.
enum Tone { case lab, warn, dim }

/// A small caption in the system font: "YOU ▸", "APPROVAL ▸", the status line.
final class MicroLabel: NSView {
    var text: String { didSet { if text != oldValue { needsDisplay = true } } }
    let tone: Tone, px: CGFloat, spacing: CGFloat, bold: Bool

    init(_ text: String = "", px: CGFloat = 10, spacing: CGFloat = 0.8, bold: Bool = true, tone: Tone = .lab) {
        (self.text, self.tone, self.px, self.spacing, self.bold) = (text, tone, px, spacing, bold)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    var font: NSFont { Chrome.ui(px, bold ? .semibold : .regular) }
    var fitting: NSSize { NSSize(width: Chrome.advance(text, font, kern: spacing) + 2, height: Chrome.metrics(font).ascent + Chrome.metrics(font).descent + 2) }

    override func draw(_ dirtyRect: NSRect) {
        let ink: NSColor
        switch tone {
        case .lab: ink = Chrome.textDim
        case .warn: ink = .systemOrange
        case .dim: ink = Chrome.faint
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
    static let font = Chrome.ui(9, .semibold)
    static let kern: CGFloat = 0.8

    init(_ name: String, hot: String? = nil, state: LedState = .unknown) { self.name = name; self.hot = hot; self.state = state }

    var label: String { state == .hot && hot != nil ? hot! : name + state.suffix }
    var width: CGFloat { 14 + Chrome.advance(label, Led.font, kern: Led.kern) + 2 }
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
        if ring {  // unknown / off: an empty ring
            Chrome.textDim.setStroke()
            let p = NSBezierPath(ovalIn: CGRect(x: c.x - 2.4, y: c.y - 2.4, width: 4.8, height: 4.8)); p.lineWidth = 1.2; p.stroke()
        } else if !lit {  // the dark half of a blink
            Chrome.textDim.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 2.7, y: c.y - 2.7, width: 5.4, height: 5.4)).fill()
        } else {
            let dot: NSColor
            switch state {
            case .ok: dot = .systemGreen
            case .warn, .loading: dot = .systemOrange
            case .bad: dot = .systemRed
            default: dot = Chrome.accent(t, hue)
            }
            let strength = motion == "pulse" ? 0.24 + 0.47 * pulse : 0.43
            NSGradient(colors: [dot.withAlphaComponent(strength), dot.withAlphaComponent(0)])!.draw(fromCenter: c, radius: 0, toCenter: c, radius: 7, options: [])
            dot.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 2.7, y: c.y - 2.7, width: 5.4, height: 5.4)).fill()
        }
        Chrome.line(label, Led.font, Chrome.textDim, kern: Led.kern, x: box.minX + 14, y: box.minY, h: box.height)
    }
}

/// The strip at the top of the pane: an orb in the accent, the bot's name, a Hermes and a microphone light, the model
/// chip on the right, a hairline under it. When too narrow the chip goes first (under 40 px it is hidden); the lights
/// and the name keep their room. The card puts it at (6, 6).
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
    private static let chipFont = Chrome.ui(10, .medium), nameFont = Chrome.ui(11, .semibold)
    private static let nameKern: CGFloat = 1.6, chipKern: CGFloat = 0.2

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
    /// What of it is drawn: a long name gives way before the lights do (the chip goes first of all).
    private(set) var shownName = ""

    private func place() {
        let lights = link.width + 6 + mic.width + 6
        shownName = Self.elided(displayName, to: max(0, bounds.width - 12 - 25 - 14 - lights), Self.nameFont, Self.nameKern)
        var x = 25 + Chrome.advance(shownName, Self.nameFont, kern: Self.nameKern) + 14
        linkX = x - 3; x += link.width + 6  // 3 px left of the dot's slot: the halo needs room
        micX = x - 3; x += mic.width + 6
        let text = Themes.chipText(theme, configuredModel: model)
        let room = bounds.width - 12 - x  // the chip's whole width (text plus 7 px padding each side)
        let shown = Self.elided(text, to: max(0, room - 14), Self.chipFont, Self.chipKern)
        let width = Chrome.advance(shown, Self.chipFont, kern: Self.chipKern) + 14
        chipText = shown
        chip = text.isEmpty || width < 40 ? nil : CGRect(x: bounds.width - 12 - width, y: ((Chrome.headerH - 17) / 2).rounded(.down), width: width, height: 17)
        needsDisplay = true
    }

    private static func elided(_ s: String, to limit: CGFloat, _ font: NSFont, _ kern: CGFloat) -> String {
        if Chrome.advance(s, font, kern: kern) <= limit { return s }
        var t = Array(s)
        while !t.isEmpty && Chrome.advance(String(t) + "…", font, kern: kern) > limit { t.removeLast() }
        return String(t) + "…"
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme, h = Chrome.headerH
        let orb = CGPoint(x: 14, y: h / 2)  // a bead of light in the accent
        NSGradient(colors: [Chrome.accent(t, hue, 0.55), Chrome.accent(t, hue, 0)])!.draw(fromCenter: orb, radius: 0, toCenter: orb, radius: 9, options: [])
        Chrome.accent(t, hue).setFill()
        NSBezierPath(ovalIn: CGRect(x: orb.x - 3.5, y: orb.y - 3.5, width: 7, height: 7)).fill()
        Chrome.line(shownName, Self.nameFont, Chrome.text, kern: Self.nameKern, x: 25, y: 0, h: h)
        link.draw(in: CGRect(x: linkX, y: 0, width: link.width, height: h), t, hue: hue)
        mic.draw(in: CGRect(x: micX, y: 0, width: mic.width, height: h), t, hue: hue)
        if let chip {
            Chrome.wash(0.08).setFill()
            NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2).fill()
            let w = Chrome.advance(chipText, Self.chipFont, kern: Self.chipKern)
            Chrome.line(chipText, Self.chipFont, Chrome.textDim, kern: Self.chipKern, x: chip.minX + ((chip.width - w) / 2).rounded(.down), y: chip.minY, h: chip.height)
        }
        Chrome.hairline.setFill()
        NSRect(x: 8, y: h - 1, width: bounds.width - 16, height: 1).fill()
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
        NSGradient(colors: [Chrome.hairline, Chrome.hairline.withAlphaComponent(0)])!.draw(in: NSRect(x: 11, y: h - 1, width: w - 11, height: 1), angle: 0)  // between the question and the answer
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

/// A capsule button on the glass: the menu chips and Allow / Deny.
final class ButtonView: NSView {
    enum Kind { case plain, allow, deny }
    var title: String { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var kind: Kind { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(_ title: String, kind: Kind = .plain) {
        (self.title, self.kind) = (title, kind)
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
        var fill = Chrome.wash(hovered ? 0.16 : 0.08), edge = NSColor.clear, ink = Chrome.text, weight = NSFont.Weight.regular
        switch kind {
        case .plain: break
        case .allow: fill = NSColor.controlAccentColor.withAlphaComponent(hovered ? 1 : 0.88); ink = .white; weight = .semibold
        case .deny: fill = hovered ? Chrome.wash(0.08) : .clear; edge = Chrome.hairline; ink = hovered ? Chrome.text : Chrome.textDim
        }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        fill.setFill(); capsule.fill()
        if edge != .clear { edge.setStroke(); capsule.lineWidth = 1; capsule.stroke() }
        let s = NSAttributedString(string: title, attributes: [.font: Chrome.ui(13, weight), .foregroundColor: ink, .kern: Chrome.qtKern(13)])
        let size = s.size()
        s.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(.down), y: ((bounds.height - size.height) / 2).rounded(.down)))
    }
}

/// A word-wrapped label: the footer (a hairline above, 6 px of padding) and the approval's well (a soft orange
/// wash with a bar at its left, rounded on the right).
final class WrapLabelView: NSView {
    enum Kind { case footer, well }
    let kind: Kind
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }

    init(_ kind: Kind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    private var font: NSFont { Chrome.ui(kind == .footer ? 11 : 12) }
    // QLabel puts half the width of an "x" in front of its text when it has a frame (a border in the style sheet)
    private var indent: CGFloat { (Chrome.advance("x", font) / 2).rounded(.down) }
    private var inset: NSEdgeInsets { kind == .footer ? NSEdgeInsets(top: 7, left: indent, bottom: 0, right: 0) : NSEdgeInsets(top: 6, left: 10 + indent, bottom: 6, right: 8) }
    private var ink: NSColor { kind == .footer ? Chrome.textDim : Chrome.text }

    /// The height the text needs at `width` (QLabel's height for width).
    func height(for width: CGFloat) -> CGFloat {
        let i = inset
        let box = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: NSSize(width: width - i.left - i.right, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return i.top + i.bottom + ceil(box.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let i = inset
        if kind == .footer {
            Chrome.hairline.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            bounds.clip()
            NSColor.systemOrange.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: -8, y: 0, width: bounds.width + 8, height: bounds.height), xRadius: 8, yRadius: 8).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }
        NSAttributedString(string: text, attributes: Chrome.attrs(font, ink)).draw(
            with: NSRect(x: i.left, y: i.top, width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom), options: [.usesLineFragmentOrigin])
    }
}
