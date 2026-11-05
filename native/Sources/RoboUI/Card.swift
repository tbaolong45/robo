// The speech card, on a pane of Liquid Glass (`GlassSurface`, behind everything): the widgets laid out in one column, the
// sizing of the text boxes and the right-click menu. The window (RoboWindow) owns the face, the clock and the agent's events;
// it drives this view through the setters below and gets callbacks back.
//
// Layout: the card is 340 wide with one column (margins 19, 42, 19, 19, spacing 8, 302 wide) in this order: menu,
// quote, status row, reply. Hidden items take no room. The header is a child at (6, 6) of the frame, not in the column, and the
// glass pane sits from (6, 6) to `Chrome.gap` short of the bottom. The owner sets the card's frame to `fittingHeight` inside `fit`.
import AppKit
import RoboCore

/// The status light's states (hud.LED_STATES).
enum LedState: String, CaseIterable, Sendable { case unknown, ok, warn, loading, bad, hot, off }

/// A right-click menu entry.
enum MenuAction: Sendable { case type, stay, quit }

/// A view that places its own children (no Auto Layout) whenever its size changes, and when the card asks.
class Placing: NSView {
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); place() }
    func place() {}
}

/// The right-click menu: three equal chips in one row.
final class MenuView: Placing {
    let type, stay, quit: ButtonView
    static let rowH: CGFloat = 28, spacing: CGFloat = 6

    init() {
        type = ButtonView("Type", symbol: "text.bubble"); stay = ButtonView("Stay", symbol: "pin"); quit = ButtonView("Quit", symbol: "xmark")
        super.init(frame: .zero)
        for b in buttons { addSubview(b) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    var buttons: [ButtonView] { [type, stay, quit] }
    var height: CGFloat { Self.rowH }

    override func place() {
        let width = (bounds.width - 2 * Self.spacing) / 3
        for (i, button) in buttons.enumerated() {
            let left = (CGFloat(i) * (width + Self.spacing)).rounded(), right = (CGFloat(i) * (width + Self.spacing) + width).rounded()
            button.frame = NSRect(x: left, y: 0, width: right - left, height: Self.rowH)
        }
    }
}

/// What you said: "You", "Follow-up", the text and the bar and hairline around them.
final class QuoteBlock: Placing {
    let background: QuoteView
    let label: MicroLabel, followUp: MicroLabel
    let text = TextBox(width: 291)

    init() {
        background = QuoteView()
        label = MicroLabel("You")
        followUp = MicroLabel("Follow-up", bold: false)
        super.init(frame: .zero)
        for v in [background, label, followUp, text] { addSubview(v) }
        followUp.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    /// A 12 px label row, 2 px, the text, 7 px for the hairline.
    var height: CGFloat { 12 + 2 + text.frame.height + 7 }

    override func place() {
        background.frame = bounds
        let tagW = followUp.fitting.width
        label.frame = NSRect(x: 11, y: 0, width: bounds.width - 11 - 2 - (followUp.isHidden ? 0 : tagW), height: 12)  // column 1 keeps its 2 px of spacing even when empty
        followUp.frame = NSRect(x: bounds.width - tagW, y: 0, width: tagW, height: 12)
        text.frame = NSRect(x: 11, y: 14, width: 291, height: text.frame.height)
    }
}

/// The typing dots and the status line (e.g. "on it…"); each takes room only while it shows.
final class StatusRow: Placing {
    let dots: TypingDotsView, label: MicroLabel
    init() {
        dots = TypingDotsView()
        label = MicroLabel("", bold: false)
        super.init(frame: .zero)
        addSubview(dots); addSubview(label)
        dots.isHidden = true; label.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    var height: CGFloat { max(dots.isHidden ? 0 : 16, label.isHidden ? 0 : label.fitting.height) }

    override func place() {
        dots.frame = NSRect(x: 0, y: 0, width: 32, height: 16)
        let x = dots.isHidden ? 0 : 40.0  // the dots sit at the left, like a chat bubble; the label 8 px after them
        label.frame = NSRect(x: x, y: 0, width: label.fitting.width, height: height)
    }
}

final class CardView: NSView {
    static let width: CGFloat = 340  // BUBBLE_W
    static let textMax: CGFloat = 300  // TEXT_MAX: the reply scrolls past this
    static let heardMax: CGFloat = 90  // HEARD_PX
    static let columnWidth: CGFloat = 302  // TEXT_W
    override var isFlipped: Bool { true }

    private(set) var theme: Theme
    /// Wraps every show or hide that changes the height: the window captures the face's place, runs `change`, then
    /// resizes to `fittingHeight`. The default just runs it.
    var fit: (_ change: () -> Void) -> Void = { $0() }
    var onReplyClick: (() -> Void)?  // left click on the reply: within 4 pt, not a link, nothing selected
    var onMenu: ((MenuAction) -> Void)?  // after the card hid the menu

    /// The glass pane: behind everything else, `Chrome.glow` in from the sides and top, `Chrome.gap` short of the bottom.
    let glass = GlassSurface()
    let header: HeaderView
    let chips: MenuView
    let quote: QuoteBlock
    let statusRow: StatusRow
    let reply = TextBox(width: 302)
    let caret: CaretView
    private var caretBox: CGRect?  // in the reply's viewport
    private var heardText = ""

    init(theme: Theme) {
        self.theme = theme
        header = HeaderView(theme: theme)
        chips = MenuView()
        quote = QuoteBlock()
        statusRow = StatusRow()
        caret = CaretView()
        super.init(frame: NSRect(x: 0, y: 0, width: CardView.width, height: Chrome.margins.top + Chrome.margins.bottom))
        for v in [glass, chips, quote, statusRow, reply, caret, header] as [NSView] { addSubview(v) }
        for v in [chips, quote, statusRow, reply] as [NSView] { v.isHidden = true }
        header.frame = NSRect(x: Chrome.glow, y: Chrome.glow, width: CardView.width - 2 * Chrome.glow, height: Chrome.headerH)
        reply.textView.onClick = { [weak self] in self?.onReplyClick?() }
        wire()
        applyTheme()
        relayout()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func wire() {
        chips.type.onClick = { [weak self] in self?.pressed(.type) }
        chips.stay.onClick = { [weak self] in self?.pressed(.stay) }
        chips.quit.onClick = { [weak self] in self?.pressed(.quit) }
    }

    private func pressed(_ action: MenuAction) { hideMenu(); onMenu?(action) }

    // MARK: theme

    func setTheme(_ t: Theme) {
        theme = t
        header.theme = t
        resumeAt = 0  // the window renders the reply again in the new look: now
        applyTheme()
        relayout()
    }

    /// Selection and link colours, the caret and the quote's text.
    private func applyTheme() {
        quote.text.style(); reply.style()
        caret.shape = theme.caret
        quote.text.setContent(Markdown.plain(heardText, font: .systemFont(ofSize: 12).italic, colour: Chrome.textDim))
    }

    // MARK: the shade

    private var bakedInk = Chrome.ink  // the ink the text in the boxes was last built with

    /// The card's turn over what is behind it: `level` (nil = the system's look) for the glass, `ink` for what is drawn on it
    /// (`Chrome.ink`). The marks repaint at once; the text, whose colour is part of its attributed string, is built again only
    /// when the ink moved by 0.02 or more (a render is about 0.7 ms at 1000 characters).
    func setShade(level: Double?, ink: Double?) {
        glass.setShade(level)
        guard ink != Chrome.ink else { return }
        Chrome.ink = ink
        repaint(self)
        let moved: Bool
        switch (bakedInk, ink) {
        case (nil, nil): moved = false
        case let (old?, new?): moved = abs(old - new) >= 0.02
        default: moved = true
        }
        guard moved else { return }
        bakedInk = ink
        applyTheme()
        if let (markdown, hiddenTail) = shownReply { render(markdown, hiddenTail) }
    }

    /// Everything but the glass draws with `Chrome`'s colours.
    private func repaint(_ view: NSView) {
        view.needsDisplay = true
        for sub in view.subviews where sub !== glass { repaint(sub) }
    }

    // MARK: header

    /// The MIC light: nil = no listener (voice off), `activity` the mind's, `noted` that the listener reported a problem,
    /// `following` that the key-less follow-up window is open (robo is listening for a reply).
    static func micState(listenerReady: Bool?, activity: Activity, noted: Bool, following: Bool) -> LedState {
        guard let ready = listenerReady else { return .off }
        if activity == .listening || following { return .hot }
        if noted { return .bad }
        return ready ? .ok : .loading
    }

    func setLights(link: LedState, mic: LedState) { header.setStatus(link: link, mic: mic) }
    func setPhase(_ now: Double) { header.setPhase(now) }

    // MARK: what you said, the status line

    func setHeard(_ text: String, followUp: Bool) {
        heardText = text
        quote.text.setContent(Markdown.plain(text, font: .systemFont(ofSize: 12).italic, colour: Chrome.textDim))
        quote.followUp.isHidden = !(followUp && !text.isEmpty)
        quote.place()
        sizeText()
    }

    /// Idempotent; asks the window to fit only when the dots or the label show or hide.
    func setStatusRow(typing: Bool, label: String) {
        let changed = label != statusRow.label.text
        statusRow.label.text = label
        if changed { statusRow.place() }  // a new text needs its own width: the last label's would cut it
        let shown = (typing, !label.isEmpty)
        if shown != (!statusRow.dots.isHidden, !statusRow.label.isHidden) {
            refit {
                statusRow.dots.isHidden = !shown.0
                statusRow.label.isHidden = !shown.1
                statusRow.isHidden = !(shown.0 || shown.1)
            }
        }
    }

    // MARK: the reply

    /// A render that took longer than this makes the next ones wait (`renderPause`): at 30 Hz a long reply would otherwise keep
    /// the main thread busy. What is skipped is not lost: the latest text is rendered when the wait is over.
    var renderBudget: TimeInterval = 0.008
    static let renderPause: TimeInterval = 0.1
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var resumeAt = 0.0
    private var pending: (markdown: String, hiddenTail: Int)?
    private var shownReply: (markdown: String, hiddenTail: Int)?  // what is on screen, to build again in another ink
    private var resume: Timer?

    /// The whole of `_render`: the Markdown of the typed prefix with its last `hiddenTail` UTF-16 units laid out but
    /// transparent, the boxes sized (the window fits when a height changed), the scroll position kept (or following the
    /// end, when it was there), the caret at the last letter.
    func setReply(markdown: String, hiddenTail: Int) {
        let start = now()
        if start < resumeAt {  // the last render was slow: keep the text, render it when the pause is over
            pending = (markdown, hiddenTail)
            if resume == nil {
                let timer = Timer(timeInterval: resumeAt - start, repeats: false) { [weak self] _ in self?.renderPending() }
                RunLoop.main.add(timer, forMode: .common)
                resume = timer
            }
            return
        }
        render(markdown, hiddenTail)
        if now() - start > renderBudget { resumeAt = now() + Self.renderPause }
    }

    private func renderPending() {
        resume = nil
        guard let (markdown, hiddenTail) = pending else { return }
        pending = nil
        let start = now()
        render(markdown, hiddenTail)
        if now() - start > renderBudget { resumeAt = now() + Self.renderPause }
    }

    private func dropPending() { pending = nil; resume?.invalidate(); resume = nil; resumeAt = 0 }

    private func render(_ markdown: String, _ hiddenTail: Int) {
        shownReply = (markdown, hiddenTail)
        let keep = reply.scrollValue
        let atEnd = keep >= reply.scrollMaximum - 4  // not scrolled up by the reader
        let text = Markdown.attributed(markdown, theme: theme, hidden: hiddenTail)
        reply.setContent(text)  // which resets the scroll position
        sizeText()
        reply.scrollValue = atEnd ? reply.scrollMaximum : keep
        placeCaret(at: max(0, text.length - hiddenTail))
    }

    /// A new exchange: nothing of the last reply stays (text, caret).
    func clearReply() {
        dropPending()
        shownReply = nil
        reply.setContent(NSAttributedString())
        caretBox = nil
        caret.isHidden = true
        sizeText()
    }

    func setCaret(show: Bool, on: Bool) {
        if caret.isHidden == show { caret.isHidden = !show }
        if show { caret.setOn(on) }
    }

    private func placeCaret(at index: Int) {
        let line = reply.cursorRect(at: index)
        caretBox = CaretView.box(for: line, theme: theme, in: reply.contentView.bounds.size)
        positionCaret()
    }

    private func positionCaret() {
        if let b = caretBox { caret.frame = b.offsetBy(dx: reply.frame.minX, dy: reply.frame.minY) }
    }

    /// Your question and the reply are as tall as their text, up to a cap, then they scroll (`_size_text`).
    private func sizeText() {
        let heard = quote.text.wantedHeight(cap: Self.heardMax), answer = reply.wantedHeight(cap: Self.textMax)
        if heard != quote.text.frame.height || answer != reply.frame.height || quote.isHidden != (heard == 0) || reply.isHidden != (answer == 0) {
            refit {
                quote.text.setBoxHeight(heard); quote.isHidden = heard == 0
                reply.setBoxHeight(answer); reply.isHidden = answer == 0
            }
        } else {
            relayout()
        }
    }

    // MARK: menu

    /// The Stay chip says what a press does next: `staying` offers Wander.
    func showMenu(staying: Bool = false) {
        chips.stay.title = staying ? "Wander" : "Stay"
        chips.stay.symbol = staying ? "figure.walk" : "pin"
        refit { chips.isHidden = false }
    }

    func hideMenu() {
        if !chips.isHidden { refit { chips.isHidden = true } }
    }

    // MARK: layout

    private var flow: [NSView] { [chips, quote, statusRow, reply].filter { !$0.isHidden } }

    private func height(of v: NSView) -> CGFloat {
        switch v {
        case chips: return chips.height
        case quote: return quote.height
        case statusRow: return statusRow.height
        default: return v.frame.height  // the reply: the height `sizeText` gave it
        }
    }

    /// The height of the card with what shows now.
    var fittingHeight: CGFloat {
        let rows = flow
        return Chrome.margins.top + Chrome.margins.bottom + rows.map(height(of:)).reduce(0, +) + Chrome.spacing * CGFloat(max(0, rows.count - 1))
    }

    /// `change` run through the window's `fit`, then the children placed.
    private func refit(_ change: () -> Void) {
        fit { [self] in change(); relayout() }
    }

    func relayout() {
        var y = Chrome.margins.top
        for (i, v) in flow.enumerated() {
            if i > 0 { y += Chrome.spacing }
            let h = height(of: v)
            v.frame = NSRect(x: Chrome.margins.left, y: y, width: Self.columnWidth, height: h)
            (v as? Placing)?.place()
            y += h
        }
        placeChrome(bounds.size)
        positionCaret()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeChrome(newSize)
    }

    /// The glass and the header, which are not part of the column.
    private func placeChrome(_ size: NSSize) {
        glass.frame = NSRect(x: Chrome.glow, y: Chrome.glow, width: size.width - 2 * Chrome.glow, height: size.height - Chrome.glow - Chrome.gap)
        header.frame = NSRect(x: Chrome.glow, y: Chrome.glow, width: size.width - 2 * Chrome.glow, height: Chrome.headerH)
    }

    /// `QWidget.underMouse`: false while hidden.
    var isUnderMouse: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

private extension NSFont {
    var italic: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask) }
}
