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

final class ChatView: NSView, NSTextFieldDelegate {
    static let header: CGFloat = 54, inputBar: CGFloat = 62, side: CGFloat = 18
    static let widthShare: CGFloat = 0.84  // of the column, for a bubble
    static let inputLines = 5  // the text box grows up to this many lines, then it scrolls

    private(set) var theme: Theme
    let reduceMotion: () -> Bool
    let glass = GlassSurface(frame: .zero, radius: Chrome.paneRadius)
    private let titleLabel = NSTextField(labelWithString: "Robo")
    let close = FirstMouseButton()
    let statusLabel = NSTextField(labelWithString: "")
    let scroll = NSScrollView()
    private let doc = FlippedView()
    let input = NSTextField()
    private let pill = PillView()
    let send = NSButton()
    let jump = FirstMouseButton()  // "jump to latest": shows while the reader is scrolled up from the end
    let empty = NSTextField(wrappingLabelWithString: "")  // what an empty conversation shows
    private let fade = CAGradientLayer()
    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?

    private(set) var turns: [Turn] = []
    private(set) var bubbles: [Int: BubbleView] = [:]
    private var shown: [Int: String] = [:]  // the text each bubble was last built from
    private var working = false
    private var live: (markdown: String, hidden: Int)?
    private var stick = true  // following the end of the conversation (until the reader scrolls up)
    private var scrollingByCode = false
    private(set) var inputExtra: CGFloat = 0  // how much taller than one line the text box is

    /// As the card's reply (`CardView.renderBudget`): a live render that took longer than this makes the next ones wait
    /// `CardView.renderPause`, so a long answer typed at 30 Hz does not keep the main thread busy. The latest text is rendered when
    /// the wait is over, and the sealed answer is built from the transcript, so nothing is lost.
    var renderBudget: TimeInterval = 0.008
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var resumeAt = 0.0
    private var resume: Timer?
    private(set) var liveRenders = 0  // how many live renders ran (a tick that waited is not one)

    init(theme: Theme, reduceMotion: @escaping () -> Bool) {
        self.theme = theme
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        addSubview(glass)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Chrome.textDim(nil)
        statusLabel.lineBreakMode = .byTruncatingTail
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScroller?.controlSize = .small
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        input.font = .systemFont(ofSize: 14)
        input.placeholderAttributedString = NSAttributedString(string: "Message Robo…", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Chrome.textDim(nil)])
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.usesSingleLineMode = false  // Return sends, Shift+Return is a new line (`control(_:textView:doCommandBy:)`)
        input.cell?.wraps = true
        input.cell?.isScrollable = false
        input.lineBreakMode = .byWordWrapping
        input.maximumNumberOfLines = 0
        input.delegate = self
        input.target = self
        input.action = #selector(submit)
        input.setAccessibilityLabel("Message to Robo")
        send.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
        send.isBordered = false
        send.imagePosition = .imageOnly
        send.target = self
        send.action = #selector(submit)
        send.setAccessibilityLabel("Send")
        send.contentTintColor = .labelColor
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close chat")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.contentTintColor = Chrome.textDim(nil)
        close.target = self
        close.action = #selector(closeChat)
        close.setAccessibilityLabel("Close chat")
        close.toolTip = "Close (Esc)"
        jump.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Jump to latest")?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        jump.isBordered = false
        jump.imagePosition = .imageOnly
        jump.target = self
        jump.action = #selector(jumpToLatest)
        jump.setAccessibilityLabel("Jump to latest")
        jump.toolTip = "Jump to latest"
        jump.contentTintColor = .labelColor
        jump.isHidden = true
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let welcome = NSMutableAttributedString(string: "Ask Robo anything\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: centred])
        welcome.append(NSAttributedString(string: "Type below, or talk to Robo.", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Chrome.textDim(nil), .paragraphStyle: centred]))
        empty.attributedStringValue = welcome
        empty.isSelectable = false
        // the conversation dissolves under the header and above the text box instead of ending on a line
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        scroll.wantsLayer = true
        scroll.layer?.mask = fade
        for v in [titleLabel, statusLabel, close, scroll, empty, jump, pill, input, send] as [NSView] { addSubview(v) }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        inputChanged()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit {
        NotificationCenter.default.removeObserver(self)
        resume?.invalidate()
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The pane the glass fills (the view minus the margin around it).
    private var pane: CGRect { bounds.insetBy(dx: ChatPanel.margin, dy: ChatPanel.margin) }

    override func layout() {
        super.layout()
        let p = pane
        glass.frame = p
        titleLabel.sizeToFit()
        titleLabel.frame.origin = CGPoint(x: p.minX + Self.side + 4, y: p.minY + 13)
        statusLabel.frame = CGRect(x: p.minX + Self.side + 4, y: p.minY + 32, width: p.width - 2 * Self.side - 40, height: 14)
        close.frame = CGRect(x: p.maxX - Self.side - 26, y: p.minY + 14, width: 26, height: 26)
        let bar = Self.inputBar + inputExtra
        scroll.frame = CGRect(x: p.minX, y: p.minY + Self.header - 6, width: p.width, height: p.height - Self.header - bar + 12)
        let h = scroll.bounds.height
        fade.frame = scroll.bounds
        fade.locations = [0, NSNumber(value: 16 / h), NSNumber(value: 1 - 14 / h), 1]
        pill.frame = CGRect(x: p.minX + Self.side, y: p.maxY - bar + 10, width: p.width - 2 * Self.side, height: 42 + inputExtra)
        send.frame = CGRect(x: pill.frame.maxX - 38, y: pill.frame.maxY - 37, width: 32, height: 32)  // stays beside the last line
        input.frame = CGRect(x: pill.frame.minX + 16, y: pill.frame.minY + 11, width: pill.frame.width - 62, height: 20 + inputExtra)
        jump.frame = CGRect(x: (p.midX - 15).rounded(), y: pill.frame.minY - 38, width: 30, height: 30)
        let emptyW = p.width - 80
        let emptyH = empty.sizeThatFits(NSSize(width: emptyW, height: .greatestFiniteMagnitude)).height.rounded(.up)
        empty.frame = CGRect(x: p.minX + 40, y: (scroll.frame.midY - emptyH / 2).rounded(), width: emptyW, height: emptyH)
        layoutRows()
    }

    // MARK: what it shows

    func setTheme(_ t: Theme) {
        theme = t
        for b in bubbles.values { b.theme = t }
        for turn in turns { build(turn, force: true) }
        layoutRows()
    }

    /// The glass at `level` (0 dark ... 1 light, nil = the system's look): the panel's appearance is set by the window.
    func setShade(_ level: Double?) { glass.setShade(level) }

    /// The one line under the title that says what Robo is doing ("Listening…", "on it…", "Listening for your reply").
    func setStatus(_ text: String) {
        let shown = Chrome.sentence(text)
        if statusLabel.stringValue != shown { statusLabel.stringValue = shown }
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
        empty.isHidden = !new.isEmpty
        applyWorking()
        layoutRows()
    }

    /// Make or refresh the bubble of `turn`.
    private func build(_ turn: Turn, force: Bool) {
        let bubble: BubbleView
        if let b = bubbles[turn.id] {
            bubble = b
        } else {
            bubble = BubbleView(turn: turn, theme: theme, textWidth: textWidth, reduceMotion: reduceMotion)
            doc.addSubview(bubble)
            bubbles[turn.id] = bubble
        }
        bubble.set(look: BubbleView.look(of: turn))
        bubble.setFooter(turn.footer)
        if turn.open {
            if force, let live {
                bubble.show(Markdown.attributed(live.markdown, theme: theme, ink: nil, hidden: live.hidden, mathWidth: textWidth), source: live.markdown)
            }
            return
        }
        guard force || shown[turn.id] != turn.text else { return }
        shown[turn.id] = turn.text
        bubble.show(turn.role == .you
            ? Markdown.plain(turn.text, font: .systemFont(ofSize: CGFloat(theme.textPx)), colour: .labelColor)
            : Markdown.attributed(turn.text, theme: theme, ink: nil, mathWidth: textWidth), source: turn.text)
    }

    /// The text of the turn being written, as far as the typewriter has revealed it (its last word laid out but not yet painted).
    /// Throttled like the card's reply: after a slow render the next ones wait, and the latest text is shown when the wait is over.
    func setLive(markdown: String, hidden: Int) {
        live = (markdown, hidden)
        let start = now()
        if start < resumeAt {
            if resume == nil {
                let timer = Timer(timeInterval: resumeAt - start, repeats: false) { [weak self] _ in
                    self?.resume = nil
                    self?.renderLive()
                }
                RunLoop.main.add(timer, forMode: .common)
                resume = timer
            }
            return
        }
        renderLive()
    }

    private func renderLive() {
        guard let live, let turn = turns.last, turn.open, let bubble = bubbles[turn.id] else { return }
        let start = now()
        liveRenders += 1
        bubble.show(Markdown.attributed(live.markdown, theme: theme, ink: nil, hidden: live.hidden, mathWidth: textWidth), source: live.markdown)
        applyWorking()
        layoutRows()
        if now() - start > renderBudget { resumeAt = now() + CardView.renderPause }
    }

    /// Robo is working: the last turn, while it has no text yet, shows the typing dots (what it is doing is the status line's).
    func setWorking(_ on: Bool) {
        guard on != working else { return }
        working = on
        applyWorking()
        layoutRows()
    }

    private func applyWorking() {
        for turn in turns {
            guard let bubble = bubbles[turn.id] else { continue }
            bubble.setWorking(working && turn.open && bubble.text.isBlank)
        }
    }

    /// Forget the live text (the turn was finished or abandoned), and any render still waiting for it.
    func endLive() {
        live = nil
        resume?.invalidate()
        resume = nil
        resumeAt = 0
    }

    /// What the last of Robo's turns says as plain text, for VoiceOver to read out when it is finished.
    var lastRoboText: String {
        guard let turn = turns.last(where: { $0.role == .robo }), let bubble = bubbles[turn.id] else { return "" }
        return bubble.spokenText
    }

    // MARK: layout

    private var columnWidth: CGFloat { max(160, pane.width) }
    private var maxBubble: CGFloat { ((columnWidth - 2 * Self.side) * Self.widthShare).rounded(.down) }
    private var textWidth: CGFloat { maxBubble - BubbleView.pad.left - BubbleView.pad.right }

    private func layoutRows() {
        let width = columnWidth, inset = BubbleView.side
        var y: CGFloat = 12
        for (i, turn) in turns.enumerated() {
            guard let v = bubbles[turn.id] else { continue }
            let nextSame = i + 1 < turns.count && turns[i + 1].role == turn.role
            let size = v.measure(maxWidth: maxBubble)
            let bodyW = v.bubbleSize.width
            let x = turn.role == .you ? width - Self.side - bodyW - inset : Self.side - inset
            v.frame = CGRect(x: x, y: y, width: max(bodyW, size.width) + 2 * inset, height: size.height)
            y += size.height + (nextSame ? 5 : 13)
        }
        let height = max(y + 6, scroll.contentSize.height)
        if doc.frame.size != CGSize(width: width, height: height) { doc.setFrameSize(CGSize(width: width, height: height)) }
        if stick { scrollToEnd() }
        updateJump()
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
        updateJump()
    }

    private func updateJump() {
        let hide = stick || doc.frame.height <= scroll.contentSize.height + 1
        if jump.isHidden != hide { jump.isHidden = hide }
    }

    @objc func jumpToLatest() {
        stick = true
        scrollToEnd()
        updateJump()
    }

    var following: Bool { stick }

    // MARK: the text box

    /// What is in the text box now (while it is edited the field editor has it).
    var typed: String { input.currentEditor()?.string ?? input.stringValue }

    @objc private func submit() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }  // nothing but spaces stays in the box and sends nothing
        input.stringValue = ""
        inputChanged()
        onSubmit?(text)
    }

    /// Return sends; Shift+Return (and Option+Return, the field's own) is a new line in the text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            submit()
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) { inputChanged() }

    /// The send button is live only with something to send, and the box is as tall as its text (one to `inputLines` lines, then
    /// the text scrolls inside it).
    func inputChanged() {
        let text = typed
        let enabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if send.isEnabled != enabled {
            send.isEnabled = enabled
            send.alphaValue = enabled ? 1 : 0.35
        }
        let font = input.font ?? .systemFont(ofSize: 14)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        let width = max(40, input.frame.width - 4)  // the field editor keeps 2 px at each side
        let measured = NSAttributedString(string: text.isEmpty || text.hasSuffix("\n") ? text + " " : text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let lines = min(Self.inputLines, max(1, Int((measured / line).rounded())))
        let extra = CGFloat(lines - 1) * line.rounded(.up)
        if extra != inputExtra {
            inputExtra = extra
            needsLayout = true
        }
    }

    func focusInput() { window?.makeFirstResponder(input) }

    @objc private func closeChat() { onClose?() }
}

/// A button that answers the first click: the chat's panel is not the key window until its text box is clicked.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The capsule behind the text box: a drop of glass with a bright rim on top (a rounded box once the text takes more lines).
final class PillView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let radius = min(bounds.height / 2, 21)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
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
