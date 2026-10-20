// The window robo lives in, its root view, and the hop from other threads to the main one.
import AppKit
import RoboCore

/// The borderless, see-through window: it floats over every Space (full-screen ones too) and never makes
/// robo the active app, so the program you work in keeps the keyboard.
final class RoboPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onBecomeKey: (() -> Void)?

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: FaceView.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true  // and so level .floating: above other apps' windows
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true  // a click on the face or the card does not take the keyboard
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }  // Escape and Cmd-C reach it once a text view asks for the keys
    override var canBecomeMain: Bool { false }
    /// The roamer decides where it may be (across displays, the menu bar line included), not AppKit.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func becomeKey() {
        super.becomeKey()
        onBecomeKey?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditKeys.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }

    /// Esc is robo's; arrows and paging belong to the reply's text view; a letter or a digit has nowhere to go
    /// on a pet, and handing it on would only make the text view beep.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { return super.sendEvent(event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let function = event.characters?.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } ?? false
        if event.keyCode == 53 {
            onEscape?()
        } else if flags.contains(.command) || function {
            super.sendEvent(event)
        }
    }
}

final class RootView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}

/// A hop to the main thread: the worker, the listener and the health poller report through these.
final class Bridge {
    weak var window: RoboWindow?
    func event(_ ev: Event) { DispatchQueue.main.async { [weak window] in window?.onEvent(ev) } }
    func heard(_ text: String) { DispatchQueue.main.async { [weak window] in window?.onHeard(text) } }
    func note(_ text: String) { DispatchQueue.main.async { [weak window] in window?.onNote(text) } }
    func link(_ state: HealthState) { DispatchQueue.main.async { [weak window] in window?.onLink(state) } }
    func calendar(_ fetched: CalendarRefresh) { DispatchQueue.main.async { [weak window] in window?.onCalendar(fetched) } }
    func radar(_ found: RadarOutcome, day: String) { DispatchQueue.main.async { [weak window] in window?.onRadar(found, day: day) } }
}
