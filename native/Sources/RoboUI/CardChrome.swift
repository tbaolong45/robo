// Everything the card draws apart from its text: the glass pane behind it, the header with its lights, the quote's bar, the
// caret, the typing dots and the buttons. The pane is the system's Liquid Glass (`NSGlassEffectView`), so the fill, the edge and the
// shadow are not painted here. The card turns light over a dark backdrop and dark over a light one (`Shade`, `Chrome.ink`,
// `GlassSurface.setShade`). Everything on it is neutral ink: only a warning (orange) or a failure (red) has a colour. The views are
// y-down (isFlipped).
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
    static let cardRadius: CGFloat = 24  // the card's pane
    static let paneRadius: CGFloat = 34  // the chat window's pane
    static let bubbleRadius: CGFloat = 19  // a chat bubble
    /// The card's single column: 6 margin + 13 padding at the sides, 6 + 26 header + 10 on top, 9 gap + 10 below.
    static let margins = NSEdgeInsets(top: 42, left: 19, bottom: 19, right: 19)
    static let spacing: CGFloat = 8
    static let bar: CGFloat = 2  // the quote's bar

    /// How the card adapts to what is behind it (main thread only): 0 = light ink (a dark card), 1 = dark ink (a light card), in
    /// between while the card turns over. nil = not known (no Screen Recording, no look yet): the system's own colours below.
    static var ink: Double?

    /// Increase Contrast (System Settings > Accessibility > Display): our ink is drawn at full strength and the veil is stronger. The
    /// system's own colours follow the setting by themselves. Read at draw time; a test sets its own.
    static var increaseContrast: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    /// The ink at `alpha`: near-white to near-black along `ink`, or the system's colour when nothing is known. Under Increase Contrast
    /// the text's alphas are 1 and a wash or a hairline is twice as strong.
    private static func inked(_ alpha: CGFloat, system: NSColor, _ ink: Double?, text: Bool = true) -> NSColor {
        guard let ink else { return system }
        let a = !increaseContrast() ? alpha : text ? 1 : min(1, 2 * alpha)
        return NSColor(white: 0.96 + (0.07 - 0.96) * ink, alpha: a)
    }

    /// The system's own colours (they resolve at draw time, so light, dark and the glass behind decide) until the card knows its
    /// backdrop, then the ink above with the alphas the system's have. The versions with an `ink:` take it from the caller: the chat
    /// window passes nil (its panel has the light or dark appearance itself, so the system's colours are right and never need a rebuild).
    static var text: NSColor { text(ink) }
    static var textDim: NSColor { textDim(ink) }
    static var hairline: NSColor { hairline(ink) }
    static func text(_ ink: Double?) -> NSColor { inked(1, system: .labelColor, ink) }
    /// Secondary text. The system's `secondaryLabelColor` is half strength, 3.5:1 on the light glass (measured), so this is our own.
    static func textDim(_ ink: Double?) -> NSColor { inked(dimAlpha, system: dimSystem, ink) }
    static let dimAlpha: CGFloat = 0.68
    private static let dimSystem = NSColor(name: "robo.dim") { NSColor(white: $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 1 : 0, alpha: increaseContrast() ? 1 : dimAlpha) }
    static func hairline(_ ink: Double?) -> NSColor { inked(0.18, system: .separatorColor, ink, text: false) }
    /// A quiet wash over glass: chips, code boxes.
    static func wash(_ alpha: CGFloat) -> NSColor { wash(alpha, ink) }
    static func wash(_ alpha: CGFloat, _ ink: Double?) -> NSColor { inked(alpha, system: washes(alpha), ink, text: false) }
    /// Black or white at `alpha`, picked when drawn. `labelColor.withAlphaComponent` was not: it kept the app's look (white on a light
    /// chat when the Mac is dark). Named, so two washes of one alpha are equal (the Markdown is compared for purity).
    private static func washes(_ alpha: CGFloat) -> NSColor {
        NSColor(name: "robo.wash.\(alpha)") { NSColor(white: $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 1 : 0, alpha: alpha) }
    }

    /// A filled button's capsule and its label: the text's own ink and its opposite.
    static var solid: NSColor { text }
    static var onSolid: NSColor {
        if let ink { return NSColor(white: ink >= 0.5 ? 0.98 : 0.07, alpha: 1) }
        return NSColor(name: "robo.onSolid") { NSColor(white: $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.07 : 0.98, alpha: 1) }
    }

    /// A status as a sentence starts: "listening" reads "Listening".
    static func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    // MARK: fonts

    static func ui(_ px: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: px, weight: weight) }

    static let monoFamily: String = {
        let have = Set(NSFontManager.shared.availableFontFamilies)
        return ["SF Mono", "Menlo"].first(where: have.contains) ?? "Menlo"
    }()

    static func mono(_ px: CGFloat, bold: Bool = false) -> NSFont {
        let regular = NSFont(name: monoFamily, size: px) ?? .monospacedSystemFont(ofSize: px, weight: .regular)
        return bold ? NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask) : regular
    }

    /// Integer font metrics (ascent and descent each rounded), which the layout is built on.
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

/// The card's glass (`NSGlassEffectView`): a plain view behind the card's other views (not their parent), so the layout is the
/// card's own.
///
/// It follows the system's light or dark until `setShade` gives it a level, then it is a light card, a dark card or a turn
/// between. A glass reads light or dark by its `appearance` (a tint barely moves that), so there are two: the light one below
/// and the dark one above it fading out as the level rises. At rest only the one that shows is kept, since glass is what costs
/// the GPU.
final class GlassSurface: NSView {
    /// How strong the veil over the glass gets once the backdrop is known: white over a light card, black over a dark one. These alone
    /// must keep secondary text at 4.5:1: while the card listens or works the glass was seen to render nearly clear (a light pane 184
    /// instead of 230 over black, 2026-11-04, cause not found). Increase Contrast (System Settings > Accessibility) takes the stronger pair.
    static var lightVeil: CGFloat { Chrome.increaseContrast() ? 0.85 : 0.70 }
    static var darkVeil: CGFloat { Chrome.increaseContrast() ? 0.85 : 0.72 }

    private let light = NSGlassEffectView()  // `.aqua`, below
    private let dark = NSGlassEffectView()  // `.darkAqua`, above
    private let veil: Veil
    /// What `setShade` was given: nil = the system's look.
    private(set) var level: Double?

    override convenience init(frame: NSRect) { self.init(frame: frame, radius: Chrome.cardRadius) }

    /// `radius`: the corner of the pane (`Chrome.cardRadius` for the card, `Chrome.paneRadius` for the chat window).
    init(frame: NSRect, radius: CGFloat) {
        veil = Veil(radius: radius)
        for glass in [light, dark] {
            glass.style = .regular
            glass.cornerRadius = radius
        }
        // Each glass keeps its appearance for life: changing it after the glass had rendered left it showing the old one
        // (seen live 2026-10-19: a dark card over black although the shade said light). Only which one shows changes.
        light.appearance = NSAppearance(named: .aqua)
        dark.appearance = NSAppearance(named: .darkAqua)
        super.init(frame: frame)
        addSubview(light)
        addSubview(dark)
        addSubview(veil)
        showSystemLook()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for v in [light, dark, veil] { v.frame = bounds }
    }

    /// 0 = a dark card, 1 = a light card, between = the turn (the dark glass fades out over the light one); nil = the system's
    /// look, one glass.
    func setShade(_ level: Double?) {
        guard level != self.level else { return }
        self.level = level
        veil.set(level)
        guard let level else {
            showSystemLook()
            return
        }
        let l = min(max(level, 0), 1)
        light.isHidden = l == 0  // the dark glass covers it
        dark.alphaValue = 1 - l
        dark.isHidden = l == 1  // and the light one is all there is
    }

    /// One glass, the one of the system's mode (the card before it knows its backdrop).
    private func showSystemLook() {
        let isDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        light.alphaValue = 1; dark.alphaValue = 1
        light.isHidden = isDark
        dark.isHidden = !isDark
    }

    /// A flat veil over the glass, to tune the card's contrast: white at `level` x `lightVeil` and black at (1 - level) x `darkVeil`.
    private final class Veil: NSView {
        private var level = 0.0
        private let radius: CGFloat

        init(radius: CGFloat) {
            self.radius = radius
            super.init(frame: .zero)
            isHidden = true
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func set(_ level: Double?) {
            isHidden = level == nil
            guard let level, level != self.level else { return }
            self.level = level
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
            NSColor.white.withAlphaComponent(level * GlassSurface.lightVeil).setFill(); shape.fill()
            NSColor.black.withAlphaComponent((1 - level) * GlassSurface.darkVeil).setFill(); shape.fill()
        }
    }
}

/// How the label of a `Led` reads; the dot's colour AND the label change with the state (hud.LED_STATES).
extension LedState {
    var suffix: String { [.warn: " …", .loading: " …", .bad: " problem", .off: " off"][self] ?? "" }
}

/// A small caption in the system font: "You", "Approval", the status line, in sentence case.
final class MicroLabel: NSView {
    var text: String { didSet { if text != oldValue { needsDisplay = true } } }
    let px: CGFloat, bold: Bool

    init(_ text: String = "", px: CGFloat = 11, bold: Bool = true) {
        (self.text, self.px, self.bold) = (text, px, bold)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    var font: NSFont { Chrome.ui(px, bold ? .semibold : .regular) }
    private var shown: String { Chrome.sentence(text) }
    var fitting: NSSize { NSSize(width: Chrome.advance(shown, font) + 2, height: Chrome.metrics(font).ascent + Chrome.metrics(font).descent + 2) }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.line(shown, font, Chrome.textDim, x: 0, y: 0, h: bounds.height)
    }
}

/// A status light with a word (the label never relies on colour alone): it shows only when something is wrong, or while the key-less
/// follow-up window listens. `blink` states flash at 1 Hz and "hot" pulses, both driven by the phase the app hands to `setPhase`.
struct Led {
    let name: String, hot: String?
    private(set) var state = LedState.unknown
    private(set) var lit = true, pulse = 1.0
    static let font = Chrome.ui(11)

    init(_ name: String, hot: String? = nil, state: LedState = .unknown) { self.name = name; self.hot = hot; self.state = state }

    var shows: Bool { state == .warn || state == .bad || state == .hot }
    var label: String { state == .hot && hot != nil ? hot! : name + state.suffix }
    var width: CGFloat { shows ? 14 + Chrome.advance(label, Led.font) + 2 : 0 }
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

    func draw(in box: CGRect) {
        guard shows else { return }
        let c = CGPoint(x: box.minX + 7, y: box.midY)
        let dot: NSColor
        switch state {
        case .warn: dot = .systemOrange
        case .bad: dot = .systemRed
        default: dot = Chrome.textDim
        }
        (lit ? dot.withAlphaComponent(motion == "pulse" ? 0.45 + 0.55 * pulse : 1) : Chrome.textDim.withAlphaComponent(0.35)).setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - 2.7, y: c.y - 2.7, width: 5.4, height: 5.4)).fill()
        Chrome.line(label, Led.font, Chrome.textDim, x: box.minX + 14, y: box.minY, h: box.height)
    }
}

/// The strip at the top of the pane: the bot's name, a hairline under it and, on the right, an agent and a microphone light when they
/// have something to say. A long name gives way before the lights do. The card puts it at (6, 6).
final class HeaderView: NSView {
    var theme: Theme { didSet { place(); needsDisplay = true } }
    private(set) var link = Led("Agent"), mic = Led("Mic", hot: "Listening", state: .off)
    /// Where each light starts (the dot's slot is 3 px to its right).
    private(set) var linkX: CGFloat = 0, micX: CGFloat = 0
    private static let nameFont = Chrome.ui(13, .semibold)

    init(theme: Theme) {
        self.theme = theme
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

    /// What of the bot's name is drawn.
    private(set) var shownName = ""

    private func place() {
        micX = bounds.width - 12 - mic.width
        linkX = micX - (mic.width > 0 && link.width > 0 ? 6 : 0) - link.width
        shownName = Self.elided(theme.botName, to: max(0, linkX - 12 - 8), Self.nameFont)
        needsDisplay = true
    }

    private static func elided(_ s: String, to limit: CGFloat, _ font: NSFont) -> String {
        if Chrome.advance(s, font) <= limit { return s }
        var t = Array(s)
        while !t.isEmpty && Chrome.advance(String(t) + "…", font) > limit { t.removeLast() }
        return String(t) + "…"
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = Chrome.headerH
        Chrome.line(shownName, Self.nameFont, Chrome.text, x: 12, y: 0, h: h)
        link.draw(in: CGRect(x: linkX, y: 0, width: link.width, height: h))
        mic.draw(in: CGRect(x: micX, y: 0, width: mic.width, height: h))
        Chrome.hairline.setFill()
        NSRect(x: 8, y: h - 1, width: bounds.width - 16, height: 1).fill()
    }
}

/// The bar and the hairline under the text of the user's quote.
final class QuoteView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height, w = bounds.width
        Chrome.textDim.setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 1, width: Chrome.bar, height: h - 2 - 7), xRadius: 1, yRadius: 1).fill()
        NSGradient(colors: [Chrome.hairline, Chrome.hairline.withAlphaComponent(0)])!.draw(in: NSRect(x: 11, y: h - 1, width: w - 11, height: 1), angle: 0)  // between the question and the answer
    }
}

/// The typing caret: a block, a bar or an underline in the text's ink, with a 1 px halo. A child of the reply's
/// viewport (never part of the document); the card keeps it over the reply and calls `place`.
final class CaretView: NSView {
    private(set) var on = true
    init() { super.init(frame: .zero); isHidden = true }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // WA_TransparentForMouseEvents

    var shape = "block" { didSet { needsDisplay = true } }  // the theme's `caret`: block | bar | under

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
        Chrome.text.withAlphaComponent(0.14).setFill(); r.fill()  // the halo
        Chrome.text.withAlphaComponent(0.8).setFill()
        switch shape {
        case "bar": NSRect(x: core.minX, y: core.minY, width: 2, height: core.height).fill()
        case "under": NSRect(x: core.minX, y: core.maxY - 2, width: core.width, height: 2).fill()
        default: core.fill()
        }
    }
}

/// Messenger-style "typing" dots: three neutral dots that hop in turn while robo thinks. The view owns
/// a 33 ms timer only while it is shown; under Reduce Motion the dots sit still and there is no timer.
final class TypingDotsView: NSView {
    static let hop: CGFloat = 4
    var colour: () -> NSColor = { Chrome.textDim }  // the card's ink; a chat bubble passes the system's
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } { didSet { sync() } }
    private(set) var timer: Timer?

    init() { super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 16)) }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { timer?.invalidate() }
    override var isFlipped: Bool { true }

    /// Vertical offset of each dot at time `t` (a wave running left to right, 1.2 s).
    static func offsets(_ t: Double) -> [CGFloat] { (0..<3).map { -hop * CGFloat(max(0, sin((t / 1.2 - Double($0) * 0.15) * 2 * .pi))) } }

    private func sync() {
        let shown = window != nil && !isHiddenOrHasHiddenAncestor && !reduceMotion()
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
        let still = reduceMotion()
        for (i, dy) in (still ? [0, 0, 0] : Self.offsets(clock())).enumerated() {
            let base = colour()
            base.withAlphaComponent(base.alphaComponent * (still ? 0.8 : 0.55 + 0.45 * Double(-dy / Self.hop))).setFill()
            NSBezierPath(ovalIn: CGRect(x: 5 + 11 * CGFloat(i) - 2.8, y: 10 + dy - 2.8, width: 5.6, height: 5.6)).fill()
        }
    }
}

/// A capsule button on the glass: the menu chips (an SF Symbol before the title), Allow / Deny and the nudge's answers. It takes the keyboard focus (Tab moves it
/// along `nextKeyView`, Space or Return presses), draws the system focus ring, and VoiceOver presses it by its title.
final class ButtonView: NSView {
    enum Kind { case plain, allow, deny }
    var title: String { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var symbol: String? { didSet { if symbol != oldValue { needsDisplay = true } } }
    var kind: Kind { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(_ title: String, symbol: String? = nil, kind: Kind = .plain) {
        (self.title, self.symbol, self.kind) = (title, symbol, kind)
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

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    }

    /// Space, Return and Enter press it (never while it is hidden: a hidden Allow must not take a stray key); Tab and Shift+Tab move on.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76: if !isHiddenOrHasHiddenAncestor { onClick?() }
        case 48: event.modifierFlags.contains(.shift) ? window?.selectKeyView(preceding: self) : window?.selectKeyView(following: self)
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        var fill = Chrome.wash(hovered ? 0.16 : 0.08), edge = NSColor.clear, ink = Chrome.text, weight = NSFont.Weight.regular
        switch kind {
        case .plain: break
        case .allow: fill = Chrome.solid.withAlphaComponent(hovered ? 1 : 0.9); ink = Chrome.onSolid; weight = .semibold
        case .deny: fill = hovered ? Chrome.wash(0.08) : .clear; edge = Chrome.textDim  // the safe answer must not be the faint one
        }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        fill.setFill(); capsule.fill()
        if edge != .clear { edge.setStroke(); capsule.lineWidth = 1; capsule.stroke() }
        let s = NSAttributedString(string: title, attributes: [.font: Chrome.ui(13, weight), .foregroundColor: ink, .kern: Chrome.qtKern(13)])
        let size = s.size()
        let glyph = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(hierarchicalColor: ink))) }
        let lead = glyph.map { $0.size.width + 5 } ?? 0
        let x = ((bounds.width - size.width - lead) / 2).rounded(.down)
        if let glyph {
            glyph.draw(in: NSRect(x: x, y: ((bounds.height - glyph.size.height) / 2).rounded(), width: glyph.size.width, height: glyph.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        s.draw(at: NSPoint(x: x + lead, y: ((bounds.height - size.height) / 2).rounded(.down)))
    }
}

/// A word-wrapped label: the footer (a hairline above, 6 px of padding), the approval's well (a soft orange wash with a bar at its left,
/// rounded on the right) and the nudge's note (a neutral wash, its first line bold).
final class WrapLabelView: NSView {
    enum Kind { case footer, well, note }
    let kind: Kind
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }

    init(_ kind: Kind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    private var font: NSFont { Chrome.ui(kind == .footer ? 11 : 12) }
    // QLabel puts half the width of an "x" in front of its text when it has a frame (a border in the style sheet)
    private var indent: CGFloat { (Chrome.advance("x", font) / 2).rounded(.down) }
    private var inset: NSEdgeInsets { kind == .footer ? NSEdgeInsets(top: 7, left: indent, bottom: 0, right: 0) : NSEdgeInsets(top: 6, left: 10 + indent, bottom: 6, right: 8) }
    /// What is drawn and what is measured: the same attributes, or a line that just fits wraps when drawn (`.kern: 0` turns pair kerning off).
    private var shown: NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: Chrome.attrs(font, ink))
        if kind == .note {
            let title = (text as NSString).range(of: "\n").location
            s.addAttribute(.font, value: Chrome.ui(12, .semibold), range: NSRange(location: 0, length: title == NSNotFound ? s.length : title))
        }
        return s
    }
    private var ink: NSColor { kind == .footer ? Chrome.textDim : Chrome.text }

    /// The height the text needs at `width` (QLabel's height for width).
    func height(for width: CGFloat) -> CGFloat {
        let i = inset
        let box = shown.boundingRect(
            with: NSSize(width: width - i.left - i.right, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return i.top + i.bottom + ceil(box.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let i = inset
        if kind == .footer {
            Chrome.hairline.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        } else if kind == .note {
            Chrome.wash(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            bounds.clip()
            NSColor.systemOrange.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: -8, y: 0, width: bounds.width + 8, height: bounds.height), xRadius: 8, yRadius: 8).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }
        shown.draw(
            with: NSRect(x: i.left, y: i.top, width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom), options: [.usesLineFragmentOrigin])
    }
}
