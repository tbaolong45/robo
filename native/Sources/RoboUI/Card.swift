// The speech card, on a pane of Liquid Glass (`GlassSurface`, behind everything): the widgets laid out in one column, the
// sizing of the text boxes, the right-click menu and the approval. The window (RoboWindow) owns the face, the clock and
// the Hermes events; it drives this view through the setters below and gets callbacks back.
//
// Layout: the card is 340 wide with one column (margins 19, 42, 19, 19, spacing 8, 302 wide) in this order: menu,
// quote, status row, reply, footer, approval. Hidden items take no room. The header is a child at (6, 6) of the frame,
// not in the column, and the glass pane sits from (6, 6) to `Chrome.gap` short of the bottom. The owner sets the card's
// frame to `fittingHeight` inside `fit`.
import AppKit
import RoboCore

/// The status light's states (hud.LED_STATES).
enum LedState: String, CaseIterable, Sendable { case unknown, ok, warn, loading, bad, hot, off }

/// A right-click menu entry.
enum MenuAction: Sendable { case digest, type, stay, watch, quit }

/// A view that places its own children (no Auto Layout) whenever its size changes, and when the card asks.
class Placing: NSView {
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); place() }
    func place() {}
}

/// The right-click menu: three chips in a row of six columns, two columns each; the second row is Watch and Quit
/// (three columns each), or just Quit (all six) when there is nothing to watch.
final class MenuView: Placing {
    let digest, type, stay, watch, quit: ButtonView
    let hasWatch: Bool
    static let rowH: CGFloat = 28, spacing: CGFloat = 6

    init(hasWatch: Bool) {
        digest = ButtonView("📚 Digest"); type = ButtonView("💬 Type"); stay = ButtonView("📌 Stay")
        watch = ButtonView("⏸ Watch"); quit = ButtonView("✕ Quit")
        self.hasWatch = hasWatch
        super.init(frame: .zero)
        for b in buttons { addSubview(b) }
        if !hasWatch { watch.isHidden = true }  // never shown, so not in the grid
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    var buttons: [ButtonView] { [digest, type, stay, watch, quit] }
    var height: CGFloat { 2 * Self.rowH + Self.spacing }

    /// The cells as (row, column, columns spanned).
    var cells: [(ButtonView, Int, Int, Int)] {
        let low = hasWatch ? [watch, quit] : [quit]
        return [digest, type, stay].enumerated().map { ($1, 0, 2 * $0, 2) }
            + low.enumerated().map { ($1, 1, 6 / low.count * $0, 6 / low.count) }
    }

    override func place() {
        let free = bounds.width - 5 * Self.spacing, width = free / 6  // six equal columns
        for (button, row, column, span) in cells {
            let left = (CGFloat(column) * (width + Self.spacing)).rounded(), right = (CGFloat(column + span - 1) * (width + Self.spacing) + width).rounded()
            button.frame = NSRect(x: left, y: CGFloat(row) * (Self.rowH + Self.spacing), width: right - left, height: Self.rowH)
        }
    }
}

/// What you said: "YOU ▸", "↳ FOLLOW-UP", the text and the bar and hairline around them.
final class QuoteBlock: Placing {
    let background: QuoteView
    let label: MicroLabel, followUp: MicroLabel
    let text = TextBox(width: 291)

    init(theme: Theme) {
        background = QuoteView(theme: theme)
        label = MicroLabel("YOU ▸")
        followUp = MicroLabel("↳ FOLLOW-UP", tone: .dim)
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

/// The typing dots and the status line (e.g. "searching the web…"); each takes room only while it shows.
final class StatusRow: Placing {
    let dots: TypingDotsView, label: MicroLabel
    init(theme: Theme) {
        dots = TypingDotsView(theme: theme)
        label = MicroLabel("", px: 11, spacing: 0.2, bold: false)
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

/// "APPROVAL ▸", the request in a well, and Allow / Deny.
final class ApprovalView: Placing {
    let label: MicroLabel, well: WrapLabelView
    let allow: ButtonView, deny: ButtonView

    override init(frame: NSRect = .zero) {
        label = MicroLabel("APPROVAL ▸", tone: .warn)
        well = WrapLabelView(.well)
        allow = ButtonView("Allow", kind: .allow)  // the system accent; Deny is the quiet one
        deny = ButtonView("Deny", kind: .deny)
        super.init(frame: .zero)
        for v in [label, well, allow, deny] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func height(for width: CGFloat) -> CGFloat { 12 + 6 + well.height(for: width) + 6 + MenuView.rowH }

    override func place() {
        let wellH = well.height(for: bounds.width), half = (bounds.width - 8) / 2
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 12)
        well.frame = NSRect(x: 0, y: 18, width: bounds.width, height: wellH)
        let y = 18 + wellH + 6
        allow.frame = NSRect(x: 0, y: y, width: half, height: MenuView.rowH)
        deny.frame = NSRect(x: half + 8, y: y, width: half, height: MenuView.rowH)
    }
}

final class CardView: NSView {
    static let width: CGFloat = 340  // BUBBLE_W
    static let textMax: CGFloat = 300  // TEXT_MAX: the reply scrolls past this
    static let heardMax: CGFloat = 90  // HEARD_PX
    static let columnWidth: CGFloat = 302  // TEXT_W
    override var isFlipped: Bool { true }

    private(set) var theme: Theme
    private(set) var hue: Double
    /// Wraps every show or hide that changes the height: the window captures the face's place, runs `change`, then
    /// resizes to `fittingHeight`. The default just runs it.
    var fit: (_ change: () -> Void) -> Void = { $0() }
    var onReplyClick: (() -> Void)?  // left click on the reply: within 4 pt, not a link, nothing selected
    var onMenu: ((MenuAction) -> Void)?  // after the card hid the menu
    var onApprove: ((String) -> Void)?  // "once" | "deny"

    /// The glass pane: behind everything else, `Chrome.glow` in from the sides and top, `Chrome.gap` short of the bottom.
    let glass = GlassSurface()
    let header: HeaderView
    let chips: MenuView
    let quote: QuoteBlock
    let statusRow: StatusRow
    let reply = TextBox(width: 302)
    let footer: WrapLabelView
    let approval: ApprovalView
    let caret: CaretView
    private var caretBox: CGRect?  // in the reply's viewport
    private var footerText = ""
    private var heardText = ""

    /// `model` is the configured model name ("claude-sonnet-5.5"), for the header chip when the theme names none.
    init(theme: Theme, hasWatch: Bool, model: String = "") {
        self.theme = theme
        hue = Chrome.quantised(theme.hue)
        header = HeaderView(theme: theme, model: model)
        chips = MenuView(hasWatch: hasWatch)
        quote = QuoteBlock(theme: theme)
        statusRow = StatusRow(theme: theme)
        footer = WrapLabelView(.footer)
        approval = ApprovalView()
        caret = CaretView(theme: theme)
        super.init(frame: NSRect(x: 0, y: 0, width: CardView.width, height: Chrome.margins.top + Chrome.margins.bottom))
        for v in [glass, chips, quote, statusRow, reply, footer, approval, caret, header] as [NSView] { addSubview(v) }
        for v in [chips, quote, statusRow, reply, footer, approval] as [NSView] { v.isHidden = true }
        header.frame = NSRect(x: Chrome.glow, y: Chrome.glow, width: CardView.width - 2 * Chrome.glow, height: Chrome.headerH)
        reply.textView.onClick = { [weak self] in self?.onReplyClick?() }
        wire()
        applyTheme()
        applyHue()
        relayout()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func wire() {
        chips.digest.onClick = { [weak self] in self?.pressed(.digest) }
        chips.type.onClick = { [weak self] in self?.pressed(.type) }
        chips.stay.onClick = { [weak self] in self?.pressed(.stay) }
        chips.watch.onClick = { [weak self] in self?.pressed(.watch) }
        chips.quit.onClick = { [weak self] in self?.pressed(.quit) }
        approval.allow.onClick = { [weak self] in self?.onApprove?("once") }
        approval.deny.onClick = { [weak self] in self?.onApprove?("deny") }
    }

    private func pressed(_ action: MenuAction) { hideMenu(); onMenu?(action) }

    // MARK: theme and hue

    func setTheme(_ t: Theme) {
        theme = t
        resumeAt = 0  // the window renders the reply again in the new look: now
        applyTheme()
        applyHue()
        relayout()
    }

    /// Follow the face's hue in 2 degree steps; true when the card repainted.
    @discardableResult func setHue(_ hue: Double) -> Bool {
        let q = Chrome.quantised(hue)
        if q == self.hue { return false }
        self.hue = q
        applyHue()
        return true
    }

    /// What follows the live hue: the glass's tint, the header, the quote's bar, the dots and the caret. Called at the face's
    /// pace (a step of 2 degrees), so it touches nothing that holds text and paints nothing but a few small marks.
    private func applyHue() {
        glass.tint(Chrome.accent(theme, hue, Self.tint))
        header.theme = theme; header.hue = hue
        quote.background.theme = theme; quote.background.hue = hue
        statusRow.dots.theme = theme; statusRow.dots.hue = hue
        caret.theme = theme; caret.hue = hue
    }

    /// How much of the accent the glass takes: enough to follow the mood, not enough to cost the text its contrast.
    static let tint = 0.10

    /// Selection and link colours, the scroll bar and the quote's text.
    private func applyTheme() {
        quote.text.style(theme); reply.style(theme)
        quote.text.setContent(Markdown.plain(heardText, font: .systemFont(ofSize: 12).italic, colour: Chrome.textDim))
    }

    // MARK: header

    /// The MIC light: nil = no listener (voice off), `activity` the mind's, `noted` that the listener reported a problem.
    static func micState(listenerReady: Bool?, activity: Activity, noted: Bool) -> LedState {
        guard let ready = listenerReady else { return .off }
        if activity == .listening { return .hot }
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
        let keep = reply.scrollValue
        let atEnd = keep >= reply.scrollMaximum - 4  // not scrolled up by the reader
        let text = Markdown.attributed(markdown, theme: theme, hidden: hiddenTail)
        reply.setContent(text)  // which resets the scroll position
        sizeText()
        reply.scrollValue = atEnd ? reply.scrollMaximum : keep
        placeCaret(at: max(0, text.length - hiddenTail))
    }

    /// A new exchange: nothing of the last reply stays (text, caret, footer).
    func clearReply() {
        dropPending()
        reply.setContent(NSAttributedString())
        caretBox = nil
        caret.isHidden = true
        footerText = ""; footer.text = ""
        sizeText()
        if !footer.isHidden { refit { footer.isHidden = true } }
    }

    func setCaret(show: Bool, on: Bool) {
        if caret.isHidden == show { caret.isHidden = !show }
        if show { caret.setOn(on) }
    }

    /// Stored and drawn when `showFooter` runs (notes and files opened: shown when the typing is done).
    func setFooter(_ text: String) { footerText = text; footer.text = text }

    func showFooter() {
        if !footerText.isEmpty && footer.isHidden { refit { footer.isHidden = false } }
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

    // MARK: approval and menu

    /// nil hides the approval; text shows it (the window grows for the buttons).
    func setApproval(_ text: String?) {
        if let text {
            approval.well.text = text
            refit { approval.isHidden = false }
        } else if !approval.isHidden {
            refit { approval.isHidden = true }
        }
    }

    func showMenu(stay: String, watch: String) {
        chips.stay.title = stay; chips.watch.title = watch
        refit { chips.isHidden = false }
    }

    func hideMenu() {
        if !chips.isHidden { refit { chips.isHidden = true } }
    }

    // MARK: layout

    private var flow: [NSView] { [chips, quote, statusRow, reply, footer, approval].filter { !$0.isHidden } }

    private func height(of v: NSView) -> CGFloat {
        switch v {
        case chips: return chips.height
        case quote: return quote.height
        case statusRow: return statusRow.height
        case footer: return footer.height(for: Self.columnWidth)
        case approval: return approval.height(for: Self.columnWidth)
        default: return v.frame.height  // the reply: the height `sizeText` gave it
        }
    }

    /// The height of the card with what shows now, wrapped footer and approval text included.
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
