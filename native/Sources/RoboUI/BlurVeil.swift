// While Robo is called (listening, or the chat window is up) the rest of the screen is blurred a little, so the pet and the chat stand out
// and nothing else pulls the eye. One see-through panel over the main display, one step BELOW the floating level the pet and the chat are
// on (so they stay sharp) and above every other app's windows; it takes no clicks (what is under it still works) and no keyboard.
// What it shows is a picture of the screen WITHOUT Robo's windows, blurred by a small radius (`Backdrop.blurSigma`) and taken again about
// once a second while it is up (the system's own blur is far too strong to be mixed in at a low opacity: the sharp screen shows through
// it as a ghost). It needs Screen Recording, which the card's look already asks for; without it, or with Reduce Transparency on, there
// is no blur at all.
import AppKit

final class BlurVeil: NSPanel {
    /// A touch of darkening over the blurred picture, so the pet and the chat stand out a little more.
    static let dim: CGFloat = 0.10
    static let refreshS = 1.0  // s between two pictures while it is up
    static let shared = BlurVeil()

    private let eye = Backdrop()  // its own: it keeps its own list of displays
    private let picture = NSView()
    private var wanted = false
    private var shown = false  // on screen (or fading in)
    private var reduceMotion = false
    private var frame0 = CGRect.zero
    private var timer: Timer?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        picture.wantsLayer = true
        picture.layer?.contentsGravity = .resize
        picture.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.dim).cgColor
        contentView = picture
        alphaValue = 0
    }

    deinit { timer?.invalidate() }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Blur the screen `frame` (AppKit coordinates: the main display), or stop. Reduce Motion: no fade.
    func set(_ on: Bool, over frame: CGRect, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        wanted = on && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if wanted {
            frame0 = frame
            if timer == nil {
                timer = commonTimer(Self.refreshS) { [weak self] in self?.take() }
                take()
            }
        } else {
            timer?.invalidate()
            timer = nil
            guard shown else { return }
            shown = false
            fade(to: 0) { [weak self] in
                if self?.shown == false { self?.orderOut(nil) }
            }
        }
    }

    /// A new picture; the first one also puts the veil on screen (so that nothing flashes before there is something to show).
    private func take() {
        eye.blurredPicture(of: frame0) { [weak self] image in
            guard let self, wanted, let image else { return }
            if self.frame != frame0 { setFrame(frame0, display: false) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.layer?.contents = image
            CATransaction.commit()
            if !shown {
                shown = true
                orderFrontRegardless()
                fade(to: 1)
            }
        }
    }

    private func fade(to alpha: CGFloat, done: (() -> Void)? = nil) {
        if reduceMotion {
            alphaValue = alpha
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = alpha > 0 ? 0.30 : 0.22
            animator().alphaValue = alpha
        }, completionHandler: { done?() })
    }
}
