// The keyboard: editing shortcuts in a pet that has no menu bar, giving the keyboard back to the app that had
// it, and the Type window's focus. Key events are built here and handed to the windows; the pasteboard is
// never touched (the editing actions are replaced by counters for the length of a test).
import AppKit
import Foundation
import ObjectiveC
import Testing
import RoboCore
@testable import RoboUI

nonisolated(unsafe) var actionHits: [String: Int] = [:]

/// Count the calls of `selector` on `cls` instead of performing them; the returned closure puts it back.
@MainActor func spy(_ cls: AnyClass, _ selector: Selector) -> () -> Void {
    let name = NSStringFromSelector(selector)
    let method = class_getInstanceMethod(cls, selector)!
    let original = method_getImplementation(method)
    actionHits[name] = 0
    let block: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in actionHits[name, default: 0] += 1 }
    method_setImplementation(method, imp_implementationWithBlock(block))
    return { method_setImplementation(method, original) }
}

@MainActor func hits(_ selector: Selector) -> Int { actionHits[NSStringFromSelector(selector), default: 0] }

@MainActor func keyEvent(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}

@MainActor func command(_ chars: String, code: UInt16, in window: NSWindow) -> NSEvent {
    keyEvent(chars, code: code, flags: .command, in: window)
}

private let copyAction = #selector(NSText.copy(_:))
private let pasteAction = #selector(NSText.paste(_:))
private let selectAllAction = #selector(NSText.selectAll(_:))

// MARK: - editing shortcuts

@MainActor @Suite(.serialized) struct EditKeyTests {
    /// robo is an accessory app (no Dock icon, no menu bar), but Cmd-C and Cmd-V only work in a text field
    /// when a main menu has Edit items: AppKit finds them through the menu.
    @Test func theMainMenuHasTheStandardEditItems() {
        let menu = RoboApp.mainMenu()
        let edit = menu.items.compactMap(\.submenu).first { $0.title == "Edit" }
        let wanted: [(String, String)] = [("undo:", "z"), ("cut:", "x"), ("copy:", "c"), ("paste:", "v"), ("selectAll:", "a")]
        let got = (edit?.items ?? []).filter { $0.action != nil }.map { (NSStringFromSelector($0.action!), $0.keyEquivalent) }
        #expect(got.map(\.0) == wanted.map(\.0) && got.map(\.1) == wanted.map(\.1), "\(got)")
        #expect((edit?.items ?? []).filter { $0.action != nil }.allSatisfy { $0.keyEquivalentModifierMask == .command })
        #expect(menu.items.count == 2 && menu.items[0].submenu != nil)  // the first item is the application's own
    }

    @Test func cmdCCopiesTheSelectedTextOfTheReplyInTheNonActivatingPanel() async {
        let r = Rig()
        defer { r.close() }
        #expect(r.makeKeyOffscreen())
        r.window.say("hello world, select me")
        let text = r.window.card.reply.textView
        r.window.panel.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        let restore = spy(NSTextView.self, copyAction)
        defer { restore() }
        #expect(r.window.panel.performKeyEquivalent(with: command("c", code: 8, in: r.window.panel)))
        #expect(hits(copyAction) == 1)
    }

    /// The whole path of a key through NSApplication, with the menu robo installs: one copy, not two.
    @Test func cmdCThroughTheApplicationCopiesOnce() async {
        _ = NSApplication.shared
        let r = Rig()
        NSApp.mainMenu = RoboApp.mainMenu()
        defer { r.close(); NSApp.mainMenu = nil }
        #expect(r.makeKeyOffscreen())
        r.window.say("hello world, select me")
        let text = r.window.card.reply.textView
        r.window.panel.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        let restore = spy(NSTextView.self, copyAction)
        defer { restore() }
        NSApp.sendEvent(command("c", code: 8, in: r.window.panel))
        #expect(hits(copyAction) == 1)
    }

    @Test func cmdVAndCmdAWorkInTheTypeWindow() async {
        let r = Rig()
        defer { r.close() }
        let panel = TypePanel(theme: Themes.cyan) { _ in }
        defer { panel.close() }
        panel.makeKey()
        panel.makeFirstResponder(panel.field)
        #expect(panel.firstResponder is NSTextView)  // the field editor
        let restorePaste = spy(NSTextView.self, pasteAction), restoreAll = spy(NSTextView.self, selectAllAction)
        defer { restorePaste(); restoreAll() }
        #expect(panel.performKeyEquivalent(with: command("v", code: 9, in: panel)))
        #expect(panel.performKeyEquivalent(with: command("a", code: 0, in: panel)))
        #expect(hits(pasteAction) == 1 && hits(selectAllAction) == 1)
    }

    @Test func otherCommandKeysAreNotSwallowed() async {
        let r = Rig()
        defer { r.close() }
        #expect(r.makeKeyOffscreen())
        #expect(!EditKeys.perform(command("q", code: 12, in: r.window.panel), in: r.window.panel))  // not ours
        #expect(!EditKeys.perform(keyEvent("c", code: 8, in: r.window.panel), in: r.window.panel))  // no Command
    }
}

// MARK: - the keyboard goes back

private let textKeyDown = #selector(NSTextView.keyDown(with:))

@MainActor @Suite(.serialized) struct KeyboardHandoffTests {
    /// Clicking the reply makes the panel key (the card's text view asks for it), and it stayed key after the
    /// card closed: every later keystroke went to the pet. The card closing gives the keyboard back.
    @Test func theKeyboardGoesBackWhenTheCardCloses() async {
        let r = Rig()
        defer { r.close() }
        #expect(r.makeKeyOffscreen())
        r.window.open()
        r.window.closeBubble()
        #expect(!r.window.panel.isKeyWindow)  // robo no longer holds the keyboard
        #expect(r.window.panel.isVisible)  // and the pet itself stays on screen
        #expect(r.activated.map(\.processIdentifier) == [r.frontmost!.processIdentifier])  // the app that had it
        r.window.closeBubble()
        #expect(r.activated.count == 1)  // once
    }

    @Test func theKeyboardIsNotHandedToAnAppWhenRoboWasNeverActive() async {
        let r = Rig()
        r.appActive = false
        defer { r.close() }
        #expect(r.makeKeyOffscreen())
        r.window.open()
        r.window.closeBubble()
        #expect(!r.window.panel.isKeyWindow && r.activated.isEmpty)
    }

    @Test func aPanelThatNeverHeldTheKeyboardActivatesNobody() async {
        let r = Rig()
        defer { r.close() }
        r.window.open()
        r.window.closeBubble()
        #expect(r.activated.isEmpty)
    }

    /// Typing on the pet has nowhere to go: no responder gets it, so nothing beeps.
    @Test func strayKeysNeverReachAResponderThatBeeps() async {
        let r = Rig()
        defer { r.close() }
        #expect(r.makeKeyOffscreen())
        r.window.say("select me")
        let text = r.window.card.reply.textView
        r.window.panel.makeFirstResponder(text)
        let restore = spy(NSTextView.self, textKeyDown)
        defer { restore() }
        r.window.panel.sendEvent(keyEvent("a", code: 0, in: r.window.panel))
        r.window.panel.sendEvent(keyEvent("7", code: 26, in: r.window.panel))
        r.window.panel.sendEvent(keyEvent(" ", code: 49, in: r.window.panel))
        #expect(hits(textKeyDown) == 0)
        // arrows still move the selection in the reply
        r.window.panel.sendEvent(keyEvent(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123, in: r.window.panel))
        #expect(hits(textKeyDown) == 1)
    }

    @Test func escapeStillWorksWhileThePanelIsKey() async {
        let r = Rig()
        defer { r.close() }
        #expect(r.makeKeyOffscreen())
        r.window.open()
        r.window.panel.sendEvent(keyEvent("\u{1b}", code: 53, in: r.window.panel))
        #expect(r.window.card.isHidden)
    }

    // MARK: the Type window

    @Test func theTypeWindowFollowsTheUserIntoFullScreenSpacesLikeThePanel() {
        let panel = TypePanel(theme: Themes.cyan) { _ in }
        defer { panel.close() }
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func closingTheTypeWindowHandsTheKeyboardBack() async throws {
        let r = Rig()
        defer { r.close() }
        let front = try #require(r.frontmost)
        var submitted: [String] = []
        for how in ["ok", "cancel", "close"] {
            r.activated = []
            let panel = TypePanel(theme: Themes.cyan, focus: r.window.machine.focus) { submitted.append($0) }
            panel.field.stringValue = "hi"
            switch how {
            case "ok": panel.ok()
            case "cancel": panel.cancelled()
            default: panel.close()  // the red button
            }
            #expect(r.activated.map(\.processIdentifier) == [front.processIdentifier], Comment(rawValue: how))
        }
        #expect(submitted == ["hi"])
    }

    @Test func theTypeWindowHandsNothingBackWhenRoboWasNotActiveOrNoOneHadIt() async {
        let r = Rig()
        defer { r.close() }
        r.appActive = false
        TypePanel(theme: Themes.cyan, focus: r.window.machine.focus) { _ in }.close()
        r.appActive = true
        r.frontmost = nil
        TypePanel(theme: Themes.cyan, focus: r.window.machine.focus) { _ in }.close()
        #expect(r.activated.isEmpty)
    }
}
