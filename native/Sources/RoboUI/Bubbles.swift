// The bubbles of the chat window: the text of one turn at a fixed width (as tall as it needs, no scroll view of its own: the chat scrolls,
// and a scroll view inside a scroll view would take the mouse wheel), and the rounded bubble around it with its footer and the "typing"
// dots. Colours are the system's own and follow the chat panel's appearance (light or dark), so they never need a rebuild.
// Views are y-down (isFlipped).
import AppKit
import RoboCore

/// One turn's markdown, laid out at `width`. Built like `TextBox` (the same text view, link confirmation and layout manager) without the
/// scroll view.
final class BubbleText: NSView {
    let textView: BoxTextView
    private let layout = RoboLayoutManager()
    private let container: NSTextContainer
    let boxWidth: CGFloat
    private(set) var contentHeight: CGFloat = 0
    /// The width the text really takes (a short line is narrower than the box), for bubbles that shrink to fit.
    private(set) var usedWidth: CGFloat = 0
    /// The text draws across the whole box (a code box, a rule, a table, a centred formula): its bubble keeps the box's width.
    private(set) var spansBox = false

    init(width: CGFloat) {
        boxWidth = width
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = BoxTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.textContainerInset = .zero; textView.isRichText = true; textView.allowsUndo = false
        textView.isVerticallyResizable = false; textView.isHorizontallyResizable = false; textView.autoresizingMask = []
        addSubview(textView)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    var string: String { textView.string }
    var isBlank: Bool { (textView.textStorage?.length ?? 0) == 0 }

    func style() {
        textView.selectedTextAttributes = [.backgroundColor: Chrome.wash(0.2, nil), .foregroundColor: NSColor.labelColor]
        textView.linkTextAttributes = [.foregroundColor: NSColor.labelColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
    }

    /// Show `s` and lay it out; returns the height it needs (0 when empty).
    @discardableResult
    func setContent(_ s: NSAttributedString) -> CGFloat {
        textView.textStorage?.setAttributedString(s)
        let trailing = s.length > 0 ? s.attribute(.trailing, at: s.length - 1, effectiveRange: nil) as? [NSAttributedString.Key: Any] : nil
        if let trailing { textView.typingAttributes = trailing }  // the empty last line takes its height from these
        layout.ensureLayout(for: container)
        spansBox = false
        let all = NSRange(location: 0, length: s.length)
        s.enumerateAttributes(in: all) { a, _, stop in
            let p = a[.paragraphStyle] as? NSParagraphStyle
            if a[.codeBox] != nil || a[.rule] != nil || a[.ruleEnd] != nil || p?.alignment == .center || p?.textBlocks.isEmpty == false {
                spansBox = true
                stop.pointee = true
            }
        }
        if s.length == 0 {
            (contentHeight, usedWidth) = (0, 0)
        } else {
            // AppKit leaves the line spacing off the last line of the text; the proportional height keeps it (as the card's box does)
            let lastStyle = (trailing?[.paragraphStyle] ?? s.attribute(.paragraphStyle, at: s.length - 1, effectiveRange: nil)) as? NSParagraphStyle
            let used = layout.usedRect(for: container)
            contentHeight = (used.height + (lastStyle?.lineSpacing ?? 0)).rounded(.up) + 2
            usedWidth = used.width.rounded(.up)
        }
        textView.setFrameSize(NSSize(width: boxWidth, height: contentHeight))
        setFrameSize(NSSize(width: boxWidth, height: contentHeight))
        return contentHeight
    }
}

/// One turn as a rounded bubble: yours on the right in a neutral wash, Robo's on the left in a brighter one, a failure in red. The view
/// is `side` wider than the body at each side, room for the soft shadow.
final class BubbleView: NSView {
    enum Look { case you, robo, failed }

    static let pad = NSEdgeInsets(top: 9, left: 13, bottom: 9, right: 13)
    static let side: CGFloat = 7
    static let footerGap: CGFloat = 3
    static let shadowTop: CGFloat = 2, shadowBottom: CGFloat = 7  // room above and below the body for its soft shadow

    let turnID: Int
    private(set) var look: Look
    var theme: Theme { didSet { needsDisplay = true } }
    let text: BubbleText
    let reduceMotion: () -> Bool
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var dots: TypingDotsView?
    /// The Markdown the bubble shows (what Copy copies: code fences and formulas as written).
    private(set) var source = ""
    /// The bubble's own size (the footer is under it, outside the rounded shape).
    private(set) var bubbleSize = CGSize.zero

    init(turn: Turn, theme: Theme, textWidth: CGFloat, reduceMotion: @escaping () -> Bool = { false }) {
        turnID = turn.id
        look = BubbleView.look(of: turn)
        self.theme = theme
        self.reduceMotion = reduceMotion
        text = BubbleText(width: textWidth)
        super.init(frame: .zero)
        text.style()
        text.textView.contextMenu = { [weak self] in self?.contextMenu() }
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = Chrome.textDim(nil)
        footerLabel.isSelectable = true
        footerLabel.maximumNumberOfLines = 0
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.drawsBackground = false
        footerLabel.isHidden = true
        addSubview(footerLabel)
        updateLabel()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    static func look(of turn: Turn) -> Look { turn.role == .you ? .you : turn.failed ? .failed : .robo }

    func set(look: Look) { if look != self.look { self.look = look; needsDisplay = true; updateLabel() } }

    /// Show `s`, built from the Markdown `source`.
    func show(_ s: NSAttributedString, source: String) {
        text.setContent(s)
        self.source = source
        updateLabel()
    }

    /// The text as VoiceOver reads it: no attachment marks (a formula is a picture to it).
    var spokenText: String { text.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// "You: ...", "Robo: ...", "Robo is typing", "Robo, failed: ...".
    private func updateLabel() {
        let who = look == .you ? "You" : look == .failed ? "Robo, failed" : "Robo"
        setAccessibilityLabel(dots != nil ? "Robo is typing" : "\(who): \(spokenText)")
    }

    /// Turn the "typing" dots on or off (a Robo turn that has no text yet; what it is doing is in the chat's status line).
    func setWorking(_ working: Bool) {
        if working && dots == nil {
            let d = TypingDotsView()
            d.colour = { Chrome.textDim(nil) }
            d.reduceMotion = reduceMotion
            addSubview(d)
            dots = d
            updateLabel()
        } else if !working, let d = dots {
            d.removeFromSuperview()
            dots = nil
            updateLabel()
        }
    }

    // MARK: Copy

    /// Robo's bubbles have Copy: the selection when there is one, else the whole answer as it was written (Markdown).
    func contextMenu() -> NSMenu? {
        guard look != .you, !source.isEmpty else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy", action: #selector(copyFromMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    @objc private func copyFromMenu() { copy(to: .general) }

    func copy(to pasteboard: NSPasteboard) {
        let selected = text.textView.selectedRange()
        pasteboard.clearContents()
        if selected.length > 0, let storage = text.textView.textStorage {
            pasteboard.setString((storage.string as NSString).substring(with: selected).replacingOccurrences(of: "\u{FFFC}", with: ""), forType: .string)
        } else {
            pasteboard.setString(source, forType: .string)
        }
    }

    func setFooter(_ lines: [String]) {
        footerLabel.stringValue = lines.joined(separator: "\n")
        footerLabel.isHidden = lines.isEmpty
    }

    /// Place the pieces for a column `maxWidth` wide and return the size the view needs. A bubble is as wide as its text, or the whole
    /// column when the text draws across it (`BubbleText.spansBox`).
    func measure(maxWidth: CGFloat) -> CGSize {
        let pad = Self.pad
        let working = dots != nil
        let innerMax = maxWidth - pad.left - pad.right
        var inner = CGSize(width: text.spansBox ? innerMax : min(innerMax, text.usedWidth), height: text.contentHeight)
        if working { inner = CGSize(width: 32, height: 16) }
        let size = CGSize(width: (inner.width + pad.left + pad.right).rounded(.up), height: (inner.height + pad.top + pad.bottom).rounded(.up))
        bubbleSize = size
        let inset = Self.side  // room at both sides for the shadow: the body is drawn this far in
        text.setFrameOrigin(NSPoint(x: inset + pad.left, y: Self.shadowTop + pad.top))
        text.isHidden = working
        dots?.frame = CGRect(x: inset + pad.left, y: Self.shadowTop + pad.top, width: 32, height: 16)
        var total = CGSize(width: size.width, height: size.height + Self.shadowTop + Self.shadowBottom)
        if !footerLabel.isHidden {
            footerLabel.preferredMaxLayoutWidth = maxWidth
            let h = footerLabel.sizeThatFits(NSSize(width: maxWidth, height: .greatestFiniteMagnitude)).height.rounded(.up)
            footerLabel.frame = CGRect(x: inset + 4, y: Self.shadowTop + size.height + Self.footerGap, width: maxWidth - 4, height: h)
            total.height += Self.footerGap + h
            total.width = max(total.width, maxWidth)  // the footer may be wider than a short bubble
        }
        return total
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = CGRect(origin: CGPoint(x: Self.side, y: Self.shadowTop), size: bubbleSize)
        guard body.width > 0 else { return }
        let shape = NSBezierPath(roundedRect: body, xRadius: Chrome.bubbleRadius, yRadius: Chrome.bubbleRadius)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill: NSColor, rim: NSColor
        switch look {
        case .you:
            fill = dark ? NSColor.white.withAlphaComponent(0.2) : NSColor.black.withAlphaComponent(0.1)
            rim = dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.05)
        case .robo:
            fill = NSColor.white.withAlphaComponent(dark ? 0.09 : 0.8)
            rim = dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.06)
        case .failed:
            fill = NSColor.systemRed.withAlphaComponent(dark ? 0.36 : 0.18)
            rim = NSColor.systemRed.withAlphaComponent(0.3)
        }
        // a soft shadow, drawn only outside the bubble (under a translucent body it would show through and dirty the glass)
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds.insetBy(dx: -30, dy: -30))
        outside.append(shape)
        outside.windingRule = .evenOdd
        outside.addClip()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.28 : 0.10)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)  // down, whichever way the view runs
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        fill.setFill()
        shape.fill()
        rim.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    /// The pop-in of a new bubble: it rises a few points and fades in with a spring. Reduce Motion skips it.
    func popIn() {
        wantsLayer = true
        guard let layer else { return }
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        (rise.fromValue, rise.toValue) = (16, 0)
        (rise.damping, rise.stiffness, rise.mass, rise.initialVelocity) = (11, 220, 1, 0)  // a little overshoot: it settles like a drop
        rise.duration = rise.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        (fade.fromValue, fade.toValue, fade.duration) = (0, 1, 0.18)
        layer.add(rise, forKey: "rise")
        layer.add(fade, forKey: "fade")
    }
}
