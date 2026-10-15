// "Ask robo": the small window of its own for typing a question (QInputDialog in app.py `_type`). Robo's
// floating panel never takes the keyboard from the app you are working in, so typing gets a window that does.
import AppKit
import RoboCore

final class TypePanel: NSPanel {
    static let size = CGSize(width: 380, height: 130)

    let field = NSTextField()
    private let onSubmit: (String) -> Void
    private let focus: Focus
    private var previous: NSRunningApplication?  // who had the keyboard before this window took it

    /// `onSubmit` gets the stripped text, never an empty one.
    init(focus: Focus = Focus(), onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        self.focus = focus
        previous = focus.other()
        super.init(contentRect: CGRect(origin: .zero, size: TypePanel.size), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "Ask robo"
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // never pulls the user out of a full-screen Space
        hidesOnDeactivate = false

        let label = NSTextField(labelWithString: "Ask robo:")  // the system's own look: light or dark as macOS is
        label.frame = CGRect(x: 20, y: 90, width: 340, height: 20)
        field.frame = CGRect(x: 20, y: 58, width: 340, height: 24)
        field.target = self
        field.action = #selector(ok)  // Return
        let okButton = NSButton(title: "OK", target: self, action: #selector(ok))
        okButton.keyEquivalent = "\r"
        okButton.frame = CGRect(x: 280, y: 14, width: 80, height: 30)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = CGRect(x: 190, y: 14, width: 80, height: 30)
        for v in [label, field, okButton, cancel] as [NSView] { contentView?.addSubview(v) }
        initialFirstResponder = field
    }

    /// Centred on a display's usable area, so it opens beside robo and not on the primary screen.
    static func frame(centredOn visible: CGRect, size: CGSize = TypePanel.size) -> CGRect {
        CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }

    func place(on visible: CGRect) { setFrame(Self.frame(centredOn: visible, size: frame.size), display: false) }

    /// In front and ready for keys (an accessory app must be activated before a text field gets any).
    func present() {
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        DispatchQueue.main.async {  // the cooperative activation is asynchronous: if it was refused, ask harder
            let bundle = Bundle.main.bundleURL
            guard !NSApp.isActive, bundle.pathExtension == "app" else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditKeys.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }

    /// However it closes (OK, Cancel, the red button), the keyboard goes back to the app that had it.
    override func close() {
        super.close()
        focus.handBack(to: previous)
        previous = nil
    }

    /// OK: close, and ask unless there is nothing but spaces.
    @objc func ok() {
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        if !typed.isEmpty { onSubmit(typed) }
    }

    @objc func cancelled() { close() }
}
