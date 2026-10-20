// The keyboard of a pet that has no menu bar: the editing shortcuts, and handing the keyboard back.
import AppKit

/// Cmd-X/C/V/A/Z for a window whose first responder is a text view or a field editor. An accessory app shows
/// no menu bar, and without Edit items in a main menu AppKit never turns these keys into cut:, copy:, paste:...
/// (the main menu robo installs does; the windows also do it themselves, because robo's panel is non-activating
/// and the menu is only consulted for an active app).
enum EditKeys {
    private static let actions: [String: Selector] = [
        "x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
        "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:")),
    ]

    /// True when `event` was an editing shortcut and the first responder took it.
    static func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.isDisjoint(with: [.option, .control, .shift]),
              let key = event.charactersIgnoringModifiers?.lowercased(), let action = actions[key],
              let responder = window.firstResponder else { return false }
        return responder.tryToPerform(action, with: window)
    }

    /// The Edit menu items (never shown: the app is an accessory).
    static func menu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("-", nil, ""),
                                     ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                     ("Paste", #selector(NSText.paste(_:)), "v"),
                                     ("Select All", #selector(NSText.selectAll(_:)), "a")] as [(String, Selector?, String)] {
            edit.addItem(action == nil ? .separator() : NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        return edit
    }
}

/// The app that had the keyboard before robo took it, and the way back to it.
struct Focus {
    var frontmost: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var appIsActive: () -> Bool = { NSApp.isActive }
    var activate: (NSRunningApplication) -> Void = Focus.bringForward

    /// The frontmost app, unless that is robo.
    func other() -> NSRunningApplication? {
        frontmost().flatMap { $0.processIdentifier == getpid() ? nil : $0 }
    }

    /// Give the keyboard back to `app`, but only if robo's app took the activation from it (a non-activating
    /// panel can hold the keyboard without that, and then `app` is still the active app).
    func handBack(to app: NSRunningApplication?) {
        if let app, appIsActive() { activate(app) }
    }

    /// macOS 14 makes the active app yield before another app may take the activation: yield, activate, and
    /// when the system still refuses open the app (which activates it).
    static func bringForward(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        if app.activate() { return }
        guard let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
