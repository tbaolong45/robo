// The chat window: a window of its own, not attached to the pet, in the middle of the main screen, where the conversation lives (your
// turns and Robo's answers as bubbles on Liquid Glass) until you tell Robo to close it. `ChatPanel` is the borderless, see-through panel
// (never key by itself, so an answer that arrives while you work elsewhere takes nothing from you; a click on the text box takes the
// keyboard); `ChatView` is the glass, the header, the scrolling bubbles and the text box. The panel's appearance (light or dark) is set
// from what is behind it (RoboWindow.chatLook), and the text and marks use the system's own colours, so they follow it without a rebuild.
import AppKit
import RoboCore

/// A view whose y runs down.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}

final class ChatPanel: NSPanel {
    static let contentSize = CGSize(width: 520, height: 640)
    static let margin: CGFloat = 6  // room around the glass for its own edge light (the card has the same)

    let chat: ChatView
    var onBecomeKey: (() -> Void)?
    var onEscape: (() -> Void)?
    var onResignKey: (() -> Void)?

    init(theme: Theme, reduceMotion: @escaping () -> Bool) {
        let m = ChatPanel.margin
        let size = CGSize(width: ChatPanel.contentSize.width + 2 * m, height: ChatPanel.contentSize.height + 2 * m)
        chat = ChatView(theme: theme, reduceMotion: reduceMotion)
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Robo chat"
        isFloatingPanel = true  // and so level .floating, like the pet
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true  // a light shadow under the whole window: it lifts off the screen a little
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true  // a click on the text box takes the keyboard; scrolling and selecting text do not
        isMovableByWindowBackground = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = chat
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Where it opens is decided by `place`, not by AppKit.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    /// Esc, while the chat has the keyboard (its text box was clicked), closes it, like "close the chat".
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func becomeKey() {
        super.becomeKey()
        onBecomeKey?()
    }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditKeys.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }

    /// The window's frame for a display's usable area (AppKit coordinates): the centre of it, no bigger than 90 % of it.
    static func frame(centredOn visible: CGRect) -> CGRect {
        let m = margin
        let w = min(contentSize.width, (visible.width * 0.9).rounded(.down)) + 2 * m
        let h = min(contentSize.height, (visible.height * 0.9).rounded(.down)) + 2 * m
        return CGRect(x: (visible.midX - w / 2).rounded(), y: (visible.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Put it in the middle of `visible` and on screen, without taking the keyboard or making Robo the active app.
    func present(on visible: CGRect) {
        let frame = Self.frame(centredOn: visible)
        if frame != self.frame { setFrame(frame, display: true) }
        orderFrontRegardless()
    }

    /// The text box has the keyboard (the field editor is the first responder).
    var inputActive: Bool { isKeyWindow && chat.input.currentEditor() != nil && firstResponder === chat.input.currentEditor() }
}

final class ChatView: NSView {
    static let header: CGFloat = 54, inputBar: CGFloat = 62, side: CGFloat = 18
    static let radius: CGFloat = 34
    static let widthShare: CGFloat = 0.84  // of the column, for a bubble

    private(set) var theme: Theme
    let reduceMotion: () -> Bool
    let glass = GlassSurface(frame: .zero, radius: ChatView.radius)
    private let titleLabel = NSTextField(labelWithString: "Robo")
    private let statusLabel = NSTextField(labelWithString: "")
    let scroll = NSScrollView()
    private let doc = FlippedView()
    let input = NSTextField()
    private let pill = PillView()
    private let send = NSButton()
    private let orb = OrbView()
    private let fade = CAGradientLayer()
    var onSubmit: ((String) -> Void)?

    private(set) var turns: [Turn] = []
    private(set) var bubbles: [Int: BubbleView] = [:]
    private var shown: [Int: String] = [:]  // the text each bubble was last built from
    private var working = false, caption = ""
    private var live: (markdown: String, hidden: Int)?
    private var stick = true  // following the end of the conversation (until the reader scrolls up)
    private var scrollingByCode = false

    init(theme: Theme, reduceMotion: @escaping () -> Bool) {
        self.theme = theme
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        addSubview(glass)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        input.placeholderString = "Reply to Robo…"
        input.font = .systemFont(ofSize: 14)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.usesSingleLineMode = true
        input.lineBreakMode = .byTruncatingTail
        input.target = self
        input.action = #selector(submit)
        send.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
        send.isBordered = false
        send.imagePosition = .imageOnly
        send.contentTintColor = Chrome.accent(theme, theme.hue, 0.95)
        send.target = self
        send.action = #selector(submit)
        glass.tint(Chrome.accent(theme, theme.hue, 0.10))  // the face's colour, a little, in the glass (as the card has)
        orb.theme = theme
        // the conversation dissolves under the header and above the text box instead of ending on a line
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        scroll.wantsLayer = true
        scroll.layer?.mask = fade
        for v in [orb, titleLabel, statusLabel, scroll, pill, input, send] as [NSView] { addSubview(v) }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The pane the glass fills (the view minus the margin around it).
    private var pane: CGRect { bounds.insetBy(dx: ChatPanel.margin, dy: ChatPanel.margin) }

    override func layout() {
        super.layout()
        let p = pane
        glass.frame = p
        orb.frame = CGRect(x: p.minX + Self.side + 4, y: p.minY + 15, width: 18, height: 18)
        titleLabel.sizeToFit()
        titleLabel.frame.origin = CGPoint(x: p.minX + Self.side + 28, y: p.minY + 13)
        statusLabel.frame = CGRect(x: p.minX + Self.side + 28, y: p.minY + 32, width: p.width - 2 * Self.side - 32, height: 14)
        scroll.frame = CGRect(x: p.minX, y: p.minY + Self.header - 6, width: p.width, height: p.height - Self.header - Self.inputBar + 12)
        let h = scroll.bounds.height
        fade.frame = scroll.bounds
        fade.locations = [0, NSNumber(value: 16 / h), NSNumber(value: 1 - 14 / h), 1]
        pill.frame = CGRect(x: p.minX + Self.side, y: p.maxY - Self.inputBar + 10, width: p.width - 2 * Self.side, height: 42)
        send.frame = CGRect(x: pill.frame.maxX - 38, y: pill.frame.minY + 5, width: 32, height: 32)
        input.frame = CGRect(x: pill.frame.minX + 16, y: pill.frame.minY + 11, width: pill.frame.width - 62, height: 20)
        layoutRows()
    }

    // MARK: what it shows

    func setTheme(_ t: Theme) {
        theme = t
        glass.tint(Chrome.accent(t, t.hue, 0.10))
        orb.theme = t
        send.contentTintColor = Chrome.accent(t, t.hue, 0.95)
        for b in bubbles.values { b.theme = t }
        for turn in turns { build(turn, force: true) }
        layoutRows()
    }

    /// The glass at `level` (0 dark ... 1 light, nil = the system's look): the panel's appearance is set by the window.
    func setShade(_ level: Double?) { glass.setShade(level) }

    func setStatus(_ text: String) {
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
        orb.pulsing = !text.isEmpty  // it breathes while Robo listens or works
    }

    /// The turns to show, after any change in the conversation: bubbles are made for new turns, updated for finished ones, dropped for
    /// the ones that left. The text of the turn being written comes from `setLive`, not from here.
    func set(turns new: [Turn]) {
        let ids = Set(new.map(\.id))
        for (id, v) in bubbles where !ids.contains(id) {
            v.removeFromSuperview()
            bubbles[id] = nil
            shown[id] = nil
        }
        let before = turns.map(\.id)
        turns = new
        for turn in new {
            let isNew = bubbles[turn.id] == nil
            build(turn, force: false)
            if isNew, !before.isEmpty || new.count > 1, !reduceMotion() { bubbles[turn.id]?.popIn() }
        }
        applyWorking()
        layoutRows()
    }

    /// Make or refresh the bubble of `turn`.
    private func build(_ turn: Turn, force: Bool) {
        let bubble: BubbleView
        if let b = bubbles[turn.id] {
            bubble = b
        } else {
            bubble = BubbleView(turn: turn, theme: theme, textWidth: textWidth)
            doc.addSubview(bubble)
            bubbles[turn.id] = bubble
        }
        bubble.set(look: BubbleView.look(of: turn))
        bubble.setFooter(turn.footer)
        if turn.open {
            if force, let live { bubble.text.setContent(Markdown.attributed(live.markdown, theme: theme, ink: nil, hidden: live.hidden, mathWidth: textWidth)) }
            return
        }
        guard force || shown[turn.id] != turn.text else { return }
        shown[turn.id] = turn.text
        bubble.text.setContent(turn.role == .you
            ? Markdown.plain(turn.text, font: .systemFont(ofSize: CGFloat(theme.textPx)), colour: .labelColor)
            : Markdown.attributed(turn.text, theme: theme, ink: nil, mathWidth: textWidth))
    }

    /// The text of the turn being written, as far as the typewriter has revealed it (its last word laid out but not yet painted).
    func setLive(markdown: String, hidden: Int) {
        live = (markdown, hidden)
        guard let turn = turns.last, turn.open, let bubble = bubbles[turn.id] else { return }
        bubble.text.setContent(Markdown.attributed(markdown, theme: theme, ink: nil, hidden: hidden, mathWidth: textWidth))
        applyWorking()
        layoutRows()
    }

    /// Robo is working: the last turn, while it has no text yet, shows the typing dots (and what it is doing under them).
    func setWorking(_ on: Bool, caption text: String) {
        guard (on, text) != (working, caption) else { return }
        (working, caption) = (on, text)
        applyWorking()
        layoutRows()
    }

    private func applyWorking() {
        for turn in turns {
            guard let bubble = bubbles[turn.id] else { continue }
            let dots = working && turn.open && bubble.text.isBlank
            bubble.setWorking(dots, caption: dots ? caption : "")
        }
    }

    /// Forget the live text (the turn was finished or abandoned).
    func endLive() { live = nil }

    // MARK: layout

    private var columnWidth: CGFloat { max(160, pane.width) }
    private var maxBubble: CGFloat { ((columnWidth - 2 * Self.side) * Self.widthShare).rounded(.down) }
    private var textWidth: CGFloat { maxBubble - BubbleView.pad.left - BubbleView.pad.right }

    private func layoutRows() {
        let width = columnWidth, inset = BubbleView.tailSize
        var y: CGFloat = 12
        for (i, turn) in turns.enumerated() {
            guard let v = bubbles[turn.id] else { continue }
            let nextSame = i + 1 < turns.count && turns[i + 1].role == turn.role
            v.tail = !nextSame
            let size = v.measure(maxWidth: maxBubble, shrink: turn.role == .you)
            let bodyW = v.bubbleSize.width
            let x = turn.role == .you ? width - Self.side - bodyW - inset : Self.side - inset
            v.frame = CGRect(x: x, y: y, width: max(bodyW, size.width) + 2 * inset, height: size.height)
            y += size.height + (nextSame ? 5 : 13)
        }
        let height = max(y + 6, scroll.contentSize.height)
        if doc.frame.size != CGSize(width: width, height: height) { doc.setFrameSize(CGSize(width: width, height: height)) }
        if stick { scrollToEnd() }
    }

    func scrollToEnd() {
        scrollingByCode = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        scrollingByCode = false
    }

    /// The reader scrolled: following the end stops when they leave the bottom and starts again when they come back to it.
    @objc private func scrolled() {
        guard !scrollingByCode else { return }
        let visible = scroll.contentView.bounds
        stick = visible.maxY >= doc.frame.height - 4
    }

    var following: Bool { stick }

    // MARK: the text box

    @objc private func submit() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        input.stringValue = ""
        if !text.isEmpty { onSubmit?(text) }
    }

    func focusInput() { window?.makeFirstResponder(input) }
}

/// The capsule behind the text box: a drop of glass with a bright rim on top.
final class PillView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(starting: NSColor.white.withAlphaComponent(dark ? 0.14 : 0.78), ending: NSColor.white.withAlphaComponent(dark ? 0.06 : 0.52))?
            .draw(in: bounds, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(dark ? 0.22 : 0.9).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

/// A small drop of the face's colour beside the title; it breathes while Robo listens or works.
final class OrbView: NSView {
    var theme = Themes.glass { didSet { needsDisplay = true } }
    var pulsing = false {
        didSet {
            guard pulsing != oldValue else { return }
            wantsLayer = true
            if pulsing {
                let a = CABasicAnimation(keyPath: "opacity")
                (a.fromValue, a.toValue, a.duration) = (1.0, 0.45, 0.9)
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer?.add(a, forKey: "breathe")
            } else {
                layer?.removeAnimation(forKey: "breathe")
            }
        }
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let halo = NSGradient(colors: [Chrome.accent(theme, theme.hue, 0.55), Chrome.accent(theme, theme.hue, 0)])
        halo?.draw(fromCenter: c, radius: 0, toCenter: c, radius: bounds.width / 2, options: [])
        let core = NSBezierPath(ovalIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
        NSGradient(starting: Chrome.accent(theme, theme.hue, 1).highlight(withLevel: 0.45) ?? .white, ending: Chrome.accent(theme, theme.hue, 1))?
            .draw(in: core, angle: 90)
    }
}
