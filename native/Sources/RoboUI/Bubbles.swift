// The bubbles of the chat window: the text of one turn at a fixed width (as tall as it needs, no scroll view of its own: the chat scrolls,
// and a scroll view inside a scroll view would take the mouse wheel), and the rounded bubble around it with its tail, its footer and the
// "typing" dots. Colours are the system's own and follow the chat panel's appearance (light or dark), so they never need a rebuild.
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

    func style(_ t: Theme) {
        textView.selectedTextAttributes = [.backgroundColor: Chrome.accent(t, t.hue, 0.35), .foregroundColor: NSColor.labelColor]
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
    }

    /// Show `s` and lay it out; returns the height it needs (0 when empty).
    @discardableResult
    func setContent(_ s: NSAttributedString) -> CGFloat {
        textView.textStorage?.setAttributedString(s)
        let trailing = s.length > 0 ? s.attribute(.trailing, at: s.length - 1, effectiveRange: nil) as? [NSAttributedString.Key: Any] : nil
        if let trailing { textView.typingAttributes = trailing }  // the empty last line takes its height from these
        layout.ensureLayout(for: container)
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

/// One turn as a rounded bubble: yours on the right in a tint of the face's colour, Robo's on the left in a quiet wash, a failure in
/// red. The last bubble of a run has a small tail at its lower corner. The view is `tailSize` wider than the body at each side.
final class BubbleView: NSView {
    enum Look { case you, robo, failed }

    static let radius: CGFloat = 19
    static let pad = NSEdgeInsets(top: 9, left: 13, bottom: 9, right: 13)
    static let tailSize: CGFloat = 7
    static let footerGap: CGFloat = 3
    static let shadowTop: CGFloat = 2, shadowBottom: CGFloat = 7  // room above and below the body for its soft shadow

    let turnID: Int
    private(set) var look: Look
    var theme: Theme { didSet { text.style(theme); dots?.theme = theme; needsDisplay = true } }
    let text: BubbleText
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var dots: TypingDotsView?
    private let captionLabel = NSTextField(labelWithString: "")
    /// The bubble's own size (the footer is under it, outside the rounded shape).
    private(set) var bubbleSize = CGSize.zero
    var tail = false { didSet { if tail != oldValue { needsDisplay = true } } }

    init(turn: Turn, theme: Theme, textWidth: CGFloat) {
        turnID = turn.id
        look = BubbleView.look(of: turn)
        self.theme = theme
        text = BubbleText(width: textWidth)
        super.init(frame: .zero)
        text.style(theme)
        addSubview(text)
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.isSelectable = true
        footerLabel.maximumNumberOfLines = 0
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.drawsBackground = false
        footerLabel.isHidden = true
        addSubview(footerLabel)
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.isHidden = true
        addSubview(captionLabel)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    static func look(of turn: Turn) -> Look { turn.role == .you ? .you : turn.failed ? .failed : .robo }

    func set(look: Look) { if look != self.look { self.look = look; needsDisplay = true } }

    /// Turn the "typing" dots on or off (a Robo turn that has no text yet), with what it is doing under them.
    func setWorking(_ working: Bool, caption: String) {
        if working && dots == nil {
            let d = TypingDotsView(theme: theme)
            addSubview(d)
            dots = d
        } else if !working, let d = dots {
            d.removeFromSuperview()
            dots = nil
        }
        captionLabel.stringValue = caption
        captionLabel.isHidden = !working || caption.isEmpty
    }

    func setFooter(_ lines: [String]) {
        footerLabel.stringValue = lines.joined(separator: "\n")
        footerLabel.isHidden = lines.isEmpty
    }

    /// Place the pieces for a column `maxWidth` wide and return the size the view needs. A bubble of yours shrinks to its text; Robo's
    /// keeps the full width while it is written (so it does not change shape under the reader) and so does a finished one.
    func measure(maxWidth: CGFloat, shrink: Bool) -> CGSize {
        let pad = Self.pad
        let working = dots != nil
        let innerMax = maxWidth - pad.left - pad.right
        var inner = CGSize(width: shrink ? min(innerMax, max(text.usedWidth, 0)) : innerMax, height: text.contentHeight)
        if working {
            inner = CGSize(width: max(32, captionLabel.isHidden ? 0 : captionLabel.intrinsicContentSize.width), height: 16 + (captionLabel.isHidden ? 0 : 16))
        }
        let size = CGSize(width: (inner.width + pad.left + pad.right).rounded(.up), height: (inner.height + pad.top + pad.bottom).rounded(.up))
        bubbleSize = size
        let inset = Self.tailSize  // room at both sides for the tail: the body is drawn this far in
        text.setFrameOrigin(NSPoint(x: inset + pad.left, y: Self.shadowTop + pad.top))
        text.isHidden = working
        if let dots {
            dots.frame = CGRect(x: inset + pad.left - 5, y: Self.shadowTop + pad.top - 1, width: 32, height: 16)
            captionLabel.frame = CGRect(x: inset + pad.left, y: Self.shadowTop + pad.top + 18, width: max(0, inner.width), height: 14)
        }
        var total = CGSize(width: size.width, height: size.height + Self.shadowTop + Self.shadowBottom)
        if !footerLabel.isHidden {
            footerLabel.preferredMaxLayoutWidth = maxWidth
            let h = footerLabel.sizeThatFits(NSSize(width: maxWidth, height: .greatestFiniteMagnitude)).height.rounded(.up)
            footerLabel.frame = CGRect(x: inset + 4, y: Self.shadowTop + size.height + Self.footerGap, width: maxWidth - 4, height: h)
            total.height += Self.footerGap + h
        }
        return total
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = CGRect(origin: CGPoint(x: Self.tailSize, y: Self.shadowTop), size: bubbleSize)
        guard body.width > 0 else { return }
        let shape = NSBezierPath(roundedRect: body, xRadius: Self.radius, yRadius: Self.radius)
        if tail {
            let t = Self.tailSize
            let right = look == .you
            let tip = right ? CGPoint(x: body.maxX + t - 1, y: body.maxY) : CGPoint(x: body.minX - t + 1, y: body.maxY)
            let a = right ? CGPoint(x: body.maxX - 12, y: body.maxY - t - 1) : CGPoint(x: body.minX + 12, y: body.maxY - t - 1)
            let b = right ? CGPoint(x: body.maxX - 2, y: body.maxY - 1) : CGPoint(x: body.minX + 2, y: body.maxY - 1)
            let beak = NSBezierPath()
            beak.move(to: a)
            beak.curve(to: tip, controlPoint1: CGPoint(x: a.x + (right ? 2 : -2), y: body.maxY - 1), controlPoint2: CGPoint(x: tip.x + (right ? -2 : 2), y: tip.y))
            beak.line(to: b)
            beak.close()
            shape.append(beak)
        }
        // Liquid: a tinted body, a sheen across its upper half like light on a drop, and a thin rim that is bright on top and fades below.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let (top, bottom, rim): (NSColor, NSColor, NSColor)
        switch look {
        case .you:
            top = Chrome.accent(theme, theme.hue, dark ? 0.62 : 0.70)
            bottom = Chrome.accent(theme, theme.hue, dark ? 0.40 : 0.48)
            rim = NSColor.white.withAlphaComponent(dark ? 0.30 : 0.65)
        case .robo:
            top = NSColor.white.withAlphaComponent(dark ? 0.16 : 0.74)
            bottom = NSColor.white.withAlphaComponent(dark ? 0.07 : 0.46)
            rim = NSColor.white.withAlphaComponent(dark ? 0.26 : 0.85)
        case .failed:
            top = NSColor.systemRed.withAlphaComponent(dark ? 0.40 : 0.34)
            bottom = NSColor.systemRed.withAlphaComponent(dark ? 0.24 : 0.20)
            rim = NSColor.white.withAlphaComponent(dark ? 0.2 : 0.5)
        }
        // a soft shadow, drawn only outside the bubble (under a translucent body it would show through and dirty the glass)
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds.insetBy(dx: -30, dy: -30))
        outside.append(shape)
        outside.windingRule = .evenOdd
        outside.addClip()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.34 : 0.15)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = NSSize(width: 0, height: -2)  // down, whichever way the view runs
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        let wide = body.insetBy(dx: -Self.tailSize, dy: 0)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(starting: top, ending: bottom)?.draw(in: wide, angle: 90)  // flipped view: 90 runs from the top down
        NSGradient(colors: [NSColor.white.withAlphaComponent(dark ? 0.14 : 0.40), NSColor.white.withAlphaComponent(0)])?
            .draw(in: CGRect(x: wide.minX, y: body.minY, width: wide.width, height: body.height * 0.55), angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        // the rim: bright over the upper half, a hint below
        shape.lineWidth = 1
        for (zone, alpha) in [(CGRect(x: wide.minX, y: body.minY - 1, width: wide.width, height: body.height * 0.5 + 1), 1.0),
                              (CGRect(x: wide.minX, y: body.midY, width: wide.width, height: body.height * 0.5 + 1), 0.16)] {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: zone).addClip()
            rim.withAlphaComponent(rim.alphaComponent * alpha).setStroke()
            shape.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
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
