// The window: the displays and their coordinates, layout, dragging across displays, the Type window, the
// menu and leaving. The rig (fake Hermes, ear, displays, clock, openers) is in TestRig.swift.
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
import RoboVoice
@testable import RoboUI

// MARK: - the displays in two coordinate systems

@Suite struct ScreenSpaceTests {
    let space = ScreenSpace(userLayout)!

    @Test func theHeightOfThePrimaryIsTheOnlyLink() async {
        #expect(space.primaryHeight == 1440)
        #expect(ScreenSpace([]) == nil)  // no display for a moment: the caller keeps the last layout
    }

    /// y = primaryHeight - (origin.y + height); the screen to the left gets a negative x and the shorter
    /// one starts lower than the primary's menu bar.
    @Test func visibleFramesBecomeTopLeftRects() async {
        #expect(space.rects(userLayout) == [Rect(0, 25, 2560, 1345), Rect(-1800, 308, 1800, 1132)])
        // the full frames: the built-in's top is at 271, as Quartz says
        #expect(space.rect(builtInDisplay.frame) == Rect(-1800, 271, 1800, 1169))
        #expect(space.rect(mainDisplay.frame) == Rect(0, 0, 2560, 1440))
    }

    @Test func aWindowFrameAndItsTopLeftConvertBothWays() async {
        let size = Vec(348, 300)
        let frame = space.frame(topLeft: Vec(-100, 500), size: size)
        #expect(frame == CGRect(x: -100, y: 640, width: 348, height: 300))  // 1440 - 500 - 300
        #expect(space.topLeft(of: frame) == Vec(-100, 500))
        for pos in [Vec(0, 0), Vec(-1800, 271), Vec(2212, 1136), Vec(-350, -20)] {
            #expect(space.topLeft(of: space.frame(topLeft: pos, size: size)) == pos)
        }
        // a window pinned to the top of the primary is at y = 0, whatever its height
        #expect(space.frame(topLeft: Vec(0, 0), size: Vec(136, 104)).maxY == 1440)
    }

    @Test func thePointerConvertsToo() async {
        #expect(space.point(CGPoint(x: -50, y: 700)) == Vec(-50, 740))
        #expect(space.point(CGPoint(x: 0, y: 1440)) == Vec(0, 0))
    }

    @Test func theDisplayUnderAPointIsFoundAcrossTheSeam() async {
        #expect(space.display(at: Vec(-900, 700), in: userLayout) == builtInDisplay)
        #expect(space.display(at: Vec(1000, 500), in: userLayout) == mainDisplay)
        // above the built-in (the dead corner left of the primary): the nearest one
        #expect(space.display(at: Vec(-900, 100), in: userLayout) == builtInDisplay)
        #expect(space.display(at: Vec(-900, 100), in: []) == nil)
    }

    /// On the real displays of this Mac (any layout) the y-flip agrees with Quartz, whose global display
    /// bounds are top-left based like Roamer's. Nothing to compare on a Mac without a display.
    @Test func theRealDisplaysAgreeWithQuartz() {
        let displays = Display.current()
        guard let space = ScreenSpace(displays) else { return }
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let quartz = CGDisplayBounds(id)
            let mine = space.rect(screen.frame)
            #expect(mine == Rect(quartz.origin.x, quartz.origin.y, quartz.width, quartz.height), "display \(id)")
            // the usable area (menu bar and Dock taken off) lies inside it, in the same plane
            let usable = space.rect(screen.visibleFrame)
            #expect(usable.x >= mine.x && usable.y >= mine.y && usable.x + usable.w <= mine.x + mine.w + 0.001
                    && usable.y + usable.h <= mine.y + mine.h + 0.001, "display \(id) usable area")
        }
    }

    /// The roamer on those screens: a window may straddle the seam where they touch, and one in the dead
    /// corner (above the shorter display) is moved onto a single screen.
    @Test func aWindowMayStraddleTheSeamButNotTheDeadCorner() async {
        let screens = space.rects(userLayout)
        let r = Roamer(screens: screens, size: Vec(348, 300), seed: 1, start: Vec(500, 600))
        r.hold(now: 0, pos: Vec(-100, 500))  // half on each, where both exist
        #expect(r.pos == Vec(-100, 500))
        r.hold(now: 0, pos: Vec(-100, 100))  // left of x = 0 there is only air above y = 308
        #expect(r.pos != Vec(-100, 100))
        let inside = screens.filter { $0.x <= r.pos.x && r.pos.x + 348 <= $0.x + $0.w && $0.y <= r.pos.y && r.pos.y + 300 <= $0.y + $0.h }
        #expect(inside.count == 1)
    }
}

// MARK: - the window

@MainActor @Suite(.serialized) struct WindowTests {
    @Test func theWindowIsABorderlessNonActivatingPanelThatFloatsOverEverySpace() async {
        let r = Rig()
        defer { r.close() }
        let p = r.window.panel
        #expect(p.styleMask.contains(.borderless) && p.styleMask.contains(.nonactivatingPanel))
        #expect(p.level == .floating && p.isFloatingPanel)
        #expect(!p.isOpaque && p.backgroundColor == .clear && !p.hasShadow)
        #expect(p.collectionBehavior.contains(.canJoinAllSpaces) && p.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(p.canBecomeKey && !p.canBecomeMain && !p.hidesOnDeactivate)
        #expect(p.contentView?.isFlipped == true)
        // it is never pushed back under the menu bar line by AppKit
        #expect(p.constrainFrameRect(CGRect(x: 0, y: 5000, width: 136, height: 104), to: nil).origin.y == 5000)
    }

    @Test func itStartsAsJustAFaceInTheBottomRightCorner() async {
        let r = Rig()
        defer { r.close() }
        #expect(r.frame.size == CGSize(width: 136, height: 104))
        #expect(r.window.card.isHidden)
        #expect(r.window.face.frame == CGRect(x: 4, y: 4, width: 128, height: 96))
        // Roam.edge (24) from the bottom-right corner of the usable area: x = 1440 - 136 - 24, 24 above the bottom
        #expect(r.frame.origin == CGPoint(x: 1280, y: 24))
        #expect(r.window.windowTopLeft == Vec(1280, 772))
    }

    /// Put the window in the middle of the display, clear of every edge.
    private func inTheMiddle(_ r: Rig) {
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(600, 500))
        r.window.move(to: r.window.roamer.pos)
    }

    @Test func theCardOpensAboveTheFaceAndTheFaceStaysWhereItIs() async {
        let r = Rig()
        defer { r.close() }
        inTheMiddle(r)
        let before = r.faceMiddle
        r.window.open()
        #expect(!r.window.card.isHidden)
        #expect(r.frame.width == 348 && r.frame.height >= 107)
        #expect(r.window.face.frame.origin.x == 110)  // (348 - 128) / 2: centred under the card
        #expect(abs(r.faceMiddle.x - before.x) < 1 && abs(r.faceMiddle.y - before.y) < 1)
        r.window.closeBubble()
        #expect(r.window.card.isHidden && r.frame.size == CGSize(width: 136, height: 104))
        #expect(abs(r.faceMiddle.x - before.x) < 1 && abs(r.faceMiddle.y - before.y) < 1)
    }

    /// The window grows upward around the face: the bottom edge stays, x moves by half the width change.
    @Test func theWindowGrowsUpwardAndSymmetricallyAroundTheFace() async {
        let r = Rig()
        defer { r.close() }
        inTheMiddle(r)
        let small = r.frame
        r.window.open()
        #expect(r.frame.minY == small.minY)  // AppKit y is up: the bottom edge is fixed
        #expect(abs(r.frame.midX - small.midX) <= 1)  // and it grows to both sides
    }

    @Test func aFaceNearAnEdgeIsKeptOnScreenWhenTheCardOpens() async {
        let r = Rig()
        defer { r.close() }
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(1300, 600))  // against the right edge
        r.window.move(to: r.window.roamer.pos)
        r.window.open()
        #expect(r.frame.maxX <= 1440 && r.frame.minX >= 0)
        #expect(r.frame.maxY <= 875)
    }

    @Test func escapeFromThePanelReachesTheWindow() async {
        let r = Rig([.event(.runEnded(status: "completed", output: "x"))])
        defer { r.close() }
        r.window.open()
        r.window.panel.onEscape?()
        #expect(r.window.card.isHidden)
    }

    // MARK: dragging

    private func at(_ r: Rig, _ p: CGPoint) {
        r.pointer = p
    }

    @Test func clickingTheFaceListensAndItIsNotADragForAFewPixels() async {
        let r = Rig()
        defer { r.close() }
        at(r, r.overFace)
        r.window.faceMouse(.press)
        at(r, CGPoint(x: r.overFace.x + 5, y: r.overFace.y))  // within the 6 px threshold
        r.window.faceMouse(.drag)
        #expect(!r.window.dragged)
        r.window.faceMouse(.release)
        #expect(r.ear.now == 1)  // a click: robo listens
        #expect(r.window.mind.activity == .listening && !r.window.card.isHidden)
    }

    @Test func theTalkKeyListensWhileHeldAndLetsGoOnRelease() async {
        let key = Hotkey()  // not registered: the test calls what the system would
        let r = Rig(hotkey: key)
        defer { r.close() }
        key.onDown()
        #expect(r.ear.holds == 1 && r.ear.releases == 0)
        #expect(r.window.mind.activity == .listening && !r.window.card.isHidden)
        key.onUp()
        #expect(r.ear.releases == 1)
    }

    @Test func theTalkKeyDoesNothingWhenTheListenerIsDead() async {
        let key = Hotkey()
        let r = Rig(hotkey: key)
        defer { r.close() }
        r.ear.running = false
        key.onDown()
        #expect(r.ear.holds == 0 && r.window.mind.activity != .listening)
    }

    @Test func aDragMovesTheWindowAndLeavesItThere() async {
        let r = Rig()
        defer { r.close() }
        let start = r.frame.origin
        let here = r.overFace
        at(r, here)
        r.window.faceMouse(.press)
        at(r, CGPoint(x: here.x - 50, y: here.y))
        r.window.faceMouse(.drag)
        #expect(r.frame.origin == CGPoint(x: start.x - 50, y: start.y))
        at(r, CGPoint(x: here.x - 50, y: here.y + 30))  // up on screen is up in AppKit
        r.window.faceMouse(.drag)
        #expect(r.frame.origin == CGPoint(x: start.x - 50, y: start.y + 30))
        r.window.faceMouse(.release)
        #expect(r.ear.now == 0)  // a drag is not a click
        #expect(r.window.roamer.heldUntil > r.clock.now() + 60)  // and it stays where it was dropped
        #expect(r.window.roamer.pos == r.window.windowTopLeft)
        for _ in 0..<10 { r.window.roam() }  // the roam tick does not pull it back
        #expect(r.frame.origin == CGPoint(x: start.x - 50, y: start.y + 30))
    }

    @Test func aDragStaysHeldOnEveryMoveNotJustAtTheEnd() async {
        let r = Rig()
        defer { r.close() }
        let here = r.overFace
        at(r, here)
        r.window.faceMouse(.press)
        at(r, CGPoint(x: here.x - 40, y: here.y))
        r.window.faceMouse(.drag)
        #expect(r.window.roamer.heldUntil > r.clock.now() + 60)  // held before the button is released
        #expect(r.window.press != nil)
    }

    @Test func aRequestWalksItToACornerAndAPressFreezesIt() async {
        let r = Rig()
        defer { r.close() }
        r.window.roamer.pos = Vec(600, 500)  // not held: it was just drifting here
        r.window.move(to: r.window.roamer.pos)
        r.window.busy = true  // a request is running
        for _ in 0..<400 { r.clock.advance(0.05); r.window.roam() }
        let roamer = r.window.roamer
        #expect(roamer.mode == .come && roamer.pos == roamer.goal && roamer.pos == r.window.windowTopLeft)
        // the bottom-left corner of the 1440x875 usable area (25 pt menu bar) for a face dropped at (600, 500)
        #expect(roamer.goal == Vec(24, 25 + 875 - roamer.size.y - 24))
        roamer.pos = Vec(600, 500)  // and now the user takes hold of the face
        r.window.move(to: roamer.pos)
        at(r, r.overFace)
        r.window.faceMouse(.press)
        for _ in 0..<40 { r.clock.advance(0.05); r.window.roam() }
        #expect(roamer.mode == .present && roamer.pos == Vec(600, 500))
    }

    @Test func aRequestAfterADropWalksItToTheCornerNearestTheDrop() async {
        let r = Rig()
        defer { r.close() }
        let roamer = r.window.roamer
        roamer.hold(now: r.clock.now(), pos: Vec(1100, 150))  // dropped by the user: held for 10 minutes
        r.window.move(to: roamer.pos)
        r.window.busy = true
        for _ in 0..<100 { r.clock.advance(0.05); r.window.roam() }
        #expect(roamer.mode == .come && roamer.pos == roamer.goal && roamer.pos == r.window.windowTopLeft)
        #expect(roamer.goal == Vec(1440 - roamer.size.x - 24, 25 + 24))  // top-right, not the bottom-right bed
    }

    /// The right-click menu opens the card, but it must not send robo off before Stay can be pressed.
    @Test func theRightClickMenuDoesNotSendItToACorner() async {
        let r = Rig()
        defer { r.close() }
        let w: RoboWindow = r.window
        w.roamer.pos = Vec(600, 500)
        w.move(to: w.roamer.pos)
        w.faceMouse(.rightPress)
        #expect(!w.card.isHidden && !w.card.chips.isHidden)
        let here = w.roamer.pos  // the window grew around the face
        for _ in 0..<100 { r.clock.advance(0.05); w.roam() }  // 5 s, before the card closes by itself
        #expect(w.roamer.mode != .come && w.roamer.pos == here && w.windowTopLeft == here)
        w.card.hideMenu()  // a chip was pressed (or the menu was dismissed) and the card is still up
        for _ in 0..<100 { r.clock.advance(0.05); w.roam() }
        #expect(w.roamer.mode == .come && w.roamer.pos == w.roamer.goal && w.roamer.pos == w.windowTopLeft)
    }

    @Test func stayPressedInTheMenuKeepsItInPlaceWhileTheCardIsUp() async {
        let r = Rig()
        defer { r.close() }
        let w: RoboWindow = r.window
        w.roamer.pos = Vec(600, 500)
        w.move(to: w.roamer.pos)
        w.faceMouse(.rightPress)
        w.menu(.stay)
        w.card.hideMenu()  // the chip hides the menu; the card stays up for a few seconds
        let here = w.roamer.pos
        w.busy = true  // and a request on top of it
        for _ in 0..<100 { r.clock.advance(0.05); w.roam() }
        #expect(w.roamer.mode == .held && w.roamer.pos == here && w.windowTopLeft == here)
    }

    /// Dragging from the main display across the seam onto the built-in one: no snap-back, straddling is
    /// fine, and it stays on the far display after the drop.
    @Test func dragAcrossDisplaysHasNoSnapBack() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        r.window.refit()
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(300, 700))  // on the main display, near the seam
        r.window.move(to: r.window.roamer.pos)
        let start = r.overFace
        at(r, start)
        r.window.faceMouse(.press)
        var xs: [Double] = []
        for step in stride(from: 100, through: 1000, by: 100) {
            at(r, CGPoint(x: start.x - Double(step), y: start.y))
            r.window.faceMouse(.drag)
            xs.append(r.window.windowTopLeft.x)
            #expect(r.window.roamer.pos == r.window.windowTopLeft, "step \(step): the roamer and the window agree")
            r.window.roam()  // a tick in the middle of the drag changes nothing
            #expect(r.window.roamer.pos == r.window.windowTopLeft)
        }
        r.window.faceMouse(.release)
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $1 < $0 })  // it followed the pointer all the way left
        #expect(r.window.windowTopLeft.x < -300)  // onto the built-in display
        let at = r.window.windowTopLeft
        for _ in 0..<30 { r.window.roam() }
        #expect(r.window.windowTopLeft == at)
        // and it was never outside the union of the two screens
        let screens = r.space.rects(userLayout)
        let w = r.frame.width, h = r.frame.height
        let area = screens.reduce(0.0) { acc, s in
            acc + max(0, min(at.x + w, s.x + s.w) - max(at.x, s.x)) * max(0, min(at.y + h, s.y + s.h) - max(at.y, s.y))
        }
        #expect(area >= w * h - 0.001)
    }

    @Test func aWindowDraggedAcrossTheSeamMayStraddleTwoDisplays() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        r.window.refit()
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(300, 700))
        r.window.move(to: r.window.roamer.pos)
        let start = r.overFace
        at(r, start)
        r.window.faceMouse(.press)
        at(r, CGPoint(x: start.x - 350, y: start.y))  // the window's right half is still on the main display
        r.window.faceMouse(.drag)
        let tl = r.window.windowTopLeft
        #expect(tl.x < 0 && tl.x + r.frame.width > 0)  // straddles x = 0
        #expect(tl.x == 300 - 350)  // exactly where the pointer put it
        r.window.faceMouse(.release)
    }

    @Test func aDropInTheDeadCornerSnapsToOneDisplay() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        r.window.refit()
        let here = r.overFace
        at(r, here)
        r.window.faceMouse(.press)
        // far up and left: above the shorter built-in display, where no screen exists
        at(r, CGPoint(x: here.x - 2000, y: here.y + 1200))
        r.window.faceMouse(.drag)
        let tl = r.window.windowTopLeft
        let inside = r.space.rects(userLayout).filter {
            $0.x <= tl.x && tl.x + r.frame.width <= $0.x + $0.w && $0.y <= tl.y && tl.y + r.frame.height <= $0.y + $0.h
        }
        #expect(inside.count == 1)
        r.window.faceMouse(.release)
    }

    @Test func aRightClickOpensTheMenuAndKeepsTheCardOpen() async {
        let r = Rig()
        defer { r.close() }
        r.window.faceMouse(.rightPress)
        #expect(!r.window.card.isHidden)
        #expect(r.window.closeAfter == 8 && r.window.closeAt > r.clock.now())  // it closes by itself in a while
    }

    @Test func aClickWhileTheBubbleIsUpWithoutARunClosesIt() async {
        let r = Rig()
        defer { r.close() }
        r.window.open(closeAfter: 8)
        #expect(r.window.closeAt > 0)
        at(r, r.overFace)
        r.window.faceMouse(.press)
        r.window.faceMouse(.release)
        #expect(r.window.card.isHidden && r.ear.now == 0)
    }

    @Test func aDeadListenerLeavesTheClickToTheTypingWindow() async {
        let r = Rig()
        defer { r.close() }
        r.ear.running = false  // its thread died after it started
        r.window.clicked()
        #expect(r.typers.count == 1 && r.ear.now == 0)  // no "listening" nobody will end
        #expect(r.window.mind.activity != .listening)
    }

    @Test func aClickWhileAnsweringStopsTheRunWhenThereIsNoMicrophone() async {
        let r = Rig([.event(.delta("long")), .wait], listener: false)
        defer { r.close() }
        r.window.ask("story")
        #expect(await pump(r.window.mind.activity == .talking))
        r.window.clicked()
        #expect(await pump(r.hermes.stopped == ["run_1"]))
        r.hermes.gate.signal()
    }

    // MARK: the screens come and go

    @Test func roamingFollowsTheMonitorsThatArePluggedIn() async {
        let r = Rig()
        defer { r.close() }
        let two = [Display(frame: CGRect(x: 0, y: 300, width: 800, height: 600), visible: CGRect(x: 0, y: 300, width: 800, height: 600)),
                   Display(frame: CGRect(x: 800, y: 0, width: 1920, height: 1080), visible: CGRect(x: 800, y: 0, width: 1920, height: 1080))]
        r.displays = [Display(frame: CGRect(x: 0, y: 0, width: 800, height: 600), visible: CGRect(x: 0, y: 0, width: 800, height: 600))]
        r.window.refit()
        r.displays = [r.displays[0], two[1]]
        r.window.screensChanged()  // an external monitor was plugged in
        #expect(await pump(r.window.roamer.screens.count == 2))
        let wide = r.window.roamer.screens
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(1500, 400))
        #expect(r.window.roamer.pos == Vec(1500, 400))  // a drop on the second screen stays there
        r.displays = []
        r.window.screensChanged()  // a display asleep for a moment lists no screens
        _ = await pump(timeout: 0.1)
        #expect(r.window.roamer.screens == wide)
        r.displays = [r.displays.isEmpty ? Display(frame: CGRect(x: 0, y: 0, width: 800, height: 600), visible: CGRect(x: 0, y: 0, width: 800, height: 600)) : r.displays[0]]
        r.window.screensChanged()  // and it was unplugged: robo comes back to the one left
        #expect(await pump(r.window.roamer.screens.count == 1))
        let s = r.window.roamer.screens[0]
        let pos = r.window.roamer.pos
        #expect(pos.x >= s.x && pos.x + r.frame.width <= s.x + s.w && pos.y + r.frame.height <= s.y + s.h)
        #expect(r.window.windowTopLeft == pos)  // and the window went there
    }

    /// With the real displays of this Mac the roamer gets all of them, each as its usable area.
    @Test func theRoamerKnowsEveryRealDisplay() async {
        let real = Display.current()
        guard !real.isEmpty else { return }
        let r = Rig()
        defer { r.close() }
        r.displays = real
        r.window.refit()
        #expect(r.window.roamer.screens == r.space.rects(real) && r.window.roamer.screens.count == NSScreen.screens.count)
        let tl = r.window.windowTopLeft
        #expect(r.window.roamer.screens.contains { $0.x <= tl.x && tl.x + r.frame.width <= $0.x + $0.w })  // and it is on one
    }

    @Test func aMonitorLeftOfThePrimaryTakesTheWindowWithNegativeX() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        r.window.screensChanged()
        #expect(await pump(r.window.roamer.screens.count == 2))
        #expect(r.window.roamer.screens == [Rect(0, 25, 2560, 1345), Rect(-1800, 308, 1800, 1132)])
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(-1000, 600))  // on the built-in display
        r.window.move(to: r.window.roamer.pos)
        #expect(r.frame.origin == CGPoint(x: -1000, y: 1440 - 600 - 104))
        #expect(r.window.windowTopLeft == Vec(-1000, 600))
        #expect(r.space.display(at: r.window.faceCentre, in: userLayout) == builtInDisplay)
    }

    @Test func theCardOpensOnADisplayToTheLeftAndTheFaceStaysThere() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        r.window.refit()
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(-900, 700))
        r.window.move(to: r.window.roamer.pos)
        let before = r.faceMiddle
        r.window.open()
        #expect(abs(r.faceMiddle.x - before.x) < 1 && abs(r.faceMiddle.y - before.y) < 1)
        #expect(r.frame.minX >= -1800 && r.frame.maxX <= 0)
    }

    @Test func anUnpluggedBuiltInBringsAWindowFromItBackToTheMainDisplay() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        r.window.refit()
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(-900, 700))
        r.window.move(to: r.window.roamer.pos)
        r.displays = [mainDisplay]
        r.window.refit()
        let tl = r.window.windowTopLeft
        #expect(tl.x >= 0 && tl.x + r.frame.width <= 2560)
        #expect(r.window.roamer.screens == [Rect(0, 25, 2560, 1345)])
    }

    @Test func aChangeOfThePrimaryHeightKeepsTheWindowWhereAppKitHasIt() async {
        let r = Rig()
        defer { r.close() }
        let taller = [Display(frame: CGRect(x: 0, y: 0, width: 1440, height: 1100),
                              visible: CGRect(x: 0, y: 0, width: 1440, height: 1075))]
        let frame = r.frame
        r.displays = taller
        r.window.refit()
        #expect(r.window.space.primaryHeight == 1100)
        #expect(r.frame == frame)  // the window did not jump: AppKit's frame is the truth
        #expect(r.window.roamer.pos == r.window.space.topLeft(of: frame))
    }

    @Test func screensAreReadAfterTheEventNotDuringIt() async {
        let r = Rig()
        defer { r.close() }
        var reads = 0
        var m = r.window.machine
        let real = m.displays
        m.displays = { reads += 1; return real() }
        r.window.machine = m
        r.window.screensChanged()
        #expect(reads == 0)  // nothing yet: the lookup is queued behind the event
        #expect(await pump(reads == 1))
    }

    @Test func theSystemsScreenChangeNotificationReachesTheWindow() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await pump(r.window.roamer.screens.count == 2))
    }

    // MARK: the Type window

    @Test func typeOpensItsOwnWindowOnTheFacesDisplayAndAsks() async {
        let r = Rig([.event(.runEnded(status: "completed", output: "ok"))])
        defer { r.close() }
        r.displays = userLayout
        r.window.refit()
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(-900, 700))  // the face is on the built-in display
        r.window.move(to: r.window.roamer.pos)
        r.window.typeText()
        let t = r.typers[0]
        // beside robo, not on the primary: centred on the built-in display's usable area
        #expect(abs(t.frame.midX - builtInDisplay.visible.midX) <= 1 && abs(t.frame.midY - builtInDisplay.visible.midY) <= 1)
        #expect(t.title == "Ask robo" && t.level == .floating && t.canBecomeKey)
        t.field.stringValue = "  what is 2+2  "
        t.ok()
        #expect(await pump(!r.hermes.asked.isEmpty && !r.window.busy))
        #expect(r.hermes.asked[0].text == "what is 2+2")
    }

    @Test func typeOnThePrimaryDisplayOpensThere() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        r.window.refit()
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(1500, 600))
        r.window.move(to: r.window.roamer.pos)
        r.window.typeText()
        let t = r.typers[0]
        #expect(abs(t.frame.midX - mainDisplay.visible.midX) <= 1 && abs(t.frame.midY - mainDisplay.visible.midY) <= 1)
    }

    @Test func nothingTypedAsksNothing() async {
        let r = Rig()
        defer { r.close() }
        r.window.typeText()
        r.typers[0].field.stringValue = "   "
        r.typers[0].ok()
        _ = await pump(timeout: 0.1)
        #expect(r.hermes.asked.isEmpty && !r.window.busy)
        r.window.typeText()  // a second one replaces the first
        #expect(r.typers.count == 2)
    }

    // MARK: the menu

    @Test func theMenuEntriesDoWhatTheyAreFor() async {
        let r = Rig([.event(.runEnded(status: "completed", output: "digest"))])
        defer { r.close() }
        r.window.menu(.type)
        #expect(r.typers.count == 1)
        r.window.menu(.digest)
        #expect(await pump(!r.hermes.asked.isEmpty && !r.window.busy))
        #expect(r.hermes.asked[0].text == RoboWindow.digestPrompt)
        r.window.menu(.quit)
        #expect(await pump(r.terminated))
    }

    @Test func stayAndWanderToggleTheHold() async {
        let r = Rig()
        defer { r.close() }
        let w: RoboWindow = r.window
        #expect(w.roamer.heldUntil < r.clock.now())
        w.menu(.stay)
        #expect(w.roamer.heldUntil > r.clock.now() + 3600)
        w.menu(.stay)  // Wander
        #expect(w.roamer.heldUntil <= r.clock.now() + 1)
    }

    @Test func theMenuPausesAndResumesWatchingAndRemembersIt() async {
        let watcher = FakeWatcher()
        let r = Rig(watcher: watcher)
        defer { r.close() }
        let file = r.dir.appendingPathComponent("watch.paused")
        #expect(watcher.started && !watcher.paused)
        r.window.menu(.watch)
        #expect(watcher.paused && FileManager.default.fileExists(atPath: file.path))
        r.window.menu(.watch)
        #expect(!watcher.paused && !FileManager.default.fileExists(atPath: file.path))
        r.window.menu(.watch)
        r.window.quit()
        #expect(await pump(watcher.stopped))
        let again = FakeWatcher()
        let r2 = Rig(watcher: again, watchPaused: true)  // still paused after a restart
        defer { r2.close() }
        #expect(again.paused && again.started)
    }

    // MARK: leaving

    @Test func closingStopsTheListenerTheWatcherAndThePoller() async {
        let watcher = FakeWatcher()
        let r = Rig(watcher: watcher, health: "http://127.0.0.1:8642/p/robo")
        defer { r.close() }
        r.window.quit()
        #expect(await pump(r.terminated))
        #expect(r.ear.stopped && watcher.stopped && r.pollers[0].stopped == 1)
    }

    // MARK: leaving without a freeze

    /// A run still being created (the gateway is down) has no id to stop. Waiting for one must not freeze
    /// the pet, which is still on screen: the waits happen off the main thread, after the panel is gone.
    @Test func quitWhileARunHasNoIdNeverBlocksTheMainThread() async {
        let r = Rig()
        defer { r.close() }
        r.window.idWait = 0.3
        r.window.lock.withLock { r.window.busy = true }
        _ = r.makeKeyOffscreen()
        let begun = Date()
        r.window.quit()
        #expect(Date().timeIntervalSince(begun) < 0.15, "quit() blocked the main thread")
        #expect(!r.window.panel.isVisible)  // the pet is gone at once
        #expect(!r.terminated)  // the process ends when the cleanup is done
        #expect(await pump(r.terminated))
        #expect(r.hermes.stopped.isEmpty && r.ear.stops == 1)
    }

    @Test func aSystemQuitRunsTheCleanupAndWaitsForIt() async {
        let watcher = FakeWatcher()
        let r = Rig([delta("x"), .wait, .event(.runEnded(status: "cancelled"))], watcher: watcher, health: "http://127.0.0.1:9")
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.mind.activity == .talking))
        _ = r.makeKeyOffscreen()
        var replied = false
        let begun = Date()
        let answer = r.window.shouldTerminate(reply: { replied = true })  // a logout or an Apple Event quit
        #expect(answer == .terminateLater && Date().timeIntervalSince(begun) < 0.15)
        #expect(!r.window.panel.isVisible && !replied)
        #expect(await pump(replied))
        #expect(r.hermes.stopped == ["run_1"], "the running request is stopped before the app ends")
        #expect(r.ear.stops == 1 && watcher.stopped && r.pollers[0].stopped == 1)
        #expect(r.window.shouldTerminate(reply: {}) == .terminateNow)  // done: nothing more to wait for
        r.hermes.gate.signal()
    }

    @Test func quitFromTheMenuAndTheTerminateItAsksForRunTheCleanupOnce() async {
        let r = Rig()
        defer { r.close() }
        r.window.menu(.quit)
        #expect(await pump(r.terminated))
        #expect(r.window.shouldTerminate(reply: {}) == .terminateNow)  // what NSApp.terminate then asks the delegate
        #expect(r.ear.stops == 1)
    }

    // MARK: energy

    /// Timers without a tolerance wake the CPU at their exact instant, 60 times a second. The face keeps half
    /// the share the others get: its 66 ms rate is the slowest that still shows a 0.15 s blink (two shut frames).
    @Test func theTimersMayBeBatchedByTheSystem() async {
        let r = Rig(cps: 55)
        defer { r.close() }
        let w = r.win
        for t in [w.ticker!, w.roamTimer!] {
            #expect(t.tolerance > 0 && t.tolerance <= t.timeInterval * 0.1 + 1e-9, "\(t.timeInterval) s: \(t.tolerance)")
        }
        w.feed("Hello there")
        #expect(w.revealer!.tolerance > 0 && w.revealer!.tolerance <= w.revealer!.timeInterval * 0.1 + 1e-9)
        for activity in Activity.allCases {
            w.face.setState(activity: activity, emotion: "neutral")
            let t = w.face.timer!
            #expect(t.tolerance > 0 && t.tolerance <= t.timeInterval * 0.05 + 1e-9, "\(activity)")
        }
        w.face.setState(activity: .sleepy, emotion: "neutral")
        // a blink is shut for 95 ms: at the slowest the timer may fire (66 ms plus its tolerance) two frames still fit
        #expect(w.face.timer!.timeInterval + w.face.timer!.tolerance <= 0.0695)
    }

    @Test func theRoamTimerSlowsDownWhileThereIsNothingToMove() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        func settled(_ interval: Double) -> Bool {
            w.roamInterval == interval && abs(w.roamTimer!.timeInterval - interval) < 1e-9
        }
        w.roam()  // resting
        #expect(settled(RoboWindow.roamSlow))
        r.clock.advance(Roam.rest.upperBound + 1)  // the rest is over: it drifts to another spot, in smooth steps
        w.roam()
        #expect(w.roamer.mode == .drift)
        #expect(settled(RoboWindow.roamFast))
        w.roamer.hold(now: r.clock.now(), pos: w.roamer.pos)  // dropped by the user: nothing moves for 10 minutes
        w.roam()
        #expect(settled(RoboWindow.roamSlow))
    }

    @Test func aSleepingRoboWalksToItsBedAtFullSpeedThenTheTimerRests() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        w.roamer.hold(now: r.clock.now(), pos: Vec(300, 300), seconds: 0)  // away from the corner
        w.move(to: w.roamer.pos)
        r.clock.advance(Mind.asleepAfter + 1)
        w.tick()
        #expect(w.mind.activity == .asleep)
        w.roam()
        #expect(w.roamInterval == RoboWindow.roamFast)  // on its way to the corner
        var steps = 0
        while w.roamer.pos != w.roamer.goal && steps < 2000 {
            r.clock.advance(RoboWindow.roamFast)
            w.roam()
            steps += 1
        }
        r.clock.advance(RoboWindow.roamFast)
        w.roam()
        #expect(w.roamer.pos == w.roamer.goal && w.roamInterval == RoboWindow.roamSlow)
    }
}

// MARK: - the backdrop: what is behind the card, and the card turning light over a dark one and dark over a light one

@Suite struct BackdropTests {
    let space = ScreenSpace(userLayout)!

    /// `rect` (AppKit, y up) becomes points from the display's own top-left, the way `sourceRect` reads them.
    @Test func theRectangleIsInTheDisplaysOwnTopLeftSpace() {
        // main display: 1440 - (1000 + 300) = 140 from its top
        #expect(Backdrop.sourceRect(for: CGRect(x: 100, y: 1000, width: 328, height: 300), on: mainDisplay.frame, space: space) == CGRect(x: 100, y: 140, width: 328, height: 300))
        // the built-in display to the left (x from -1800) and shorter: its top is at 271 in the y-down plane
        #expect(Backdrop.sourceRect(for: CGRect(x: -1000, y: 500, width: 328, height: 300), on: builtInDisplay.frame, space: space) == CGRect(x: 800, y: 369, width: 328, height: 300))
        #expect(Backdrop.sourceRect(for: CGRect(x: 0, y: 1140, width: 10, height: 300), on: mainDisplay.frame, space: space) == CGRect(x: 0, y: 0, width: 10, height: 300))  // flush with the top
    }

    @Test func aRectangleHangingOffTheDisplayIsCutToIt() {
        #expect(Backdrop.sourceRect(for: CGRect(x: 2400, y: 500, width: 328, height: 100), on: mainDisplay.frame, space: space) == CGRect(x: 2400, y: 840, width: 160, height: 100))
        #expect(Backdrop.sourceRect(for: CGRect(x: 5000, y: 500, width: 328, height: 100), on: mainDisplay.frame, space: space) == nil)  // none of it there
        #expect(Backdrop.sourceRect(for: CGRect(x: 2559.5, y: 500, width: 328, height: 100), on: mainDisplay.frame, space: space) == nil)  // under a point
    }

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, left: CGFloat? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        if let left {  // the left half in another grey
            ctx.setFillColor(CGColor(srgbRed: left, green: left, blue: left, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return ctx.makeImage()!
    }

    @Test func aPictureBecomesItsMeanLumaWithTheChannelsInTheRightOrder() {
        #expect(Backdrop.luma(of: solid(0, 0, 0)) == 0)
        #expect(Backdrop.luma(of: solid(1, 1, 1))! > 0.999)
        #expect(abs(Backdrop.luma(of: solid(1, 1, 1, left: 0))! - 0.5) < 0.01)
        #expect(abs(Backdrop.luma(of: solid(1, 0, 0))! - 0.2126) < 0.01)  // red, green and blue weigh differently: B, G, R is the order
        #expect(abs(Backdrop.luma(of: solid(0, 1, 0))! - 0.7152) < 0.01)
        #expect(abs(Backdrop.luma(of: solid(0, 0, 1))! - 0.0722) < 0.01)
    }
}

@MainActor @Suite(.serialized) struct WindowShadeTests {
    private func steps(_ r: Rig, _ n: Int) { for _ in 0..<n { r.step() } }

    /// Open the card over a backdrop of `luma` and let the first look arrive: the card is known and at rest.
    private func opened(_ luma: Double?) -> Rig {
        let r = Rig()
        r.backdrop = luma
        r.window.open()
        return r
    }

    @Test func nothingLooksWhileTheCardIsHiddenAndNothingAfterItClosed() {
        let r = Rig()
        defer { r.close() }
        r.backdrop = 0.0
        steps(r, 60)
        #expect(r.looks.isEmpty && r.window.shadeTimer == nil && !r.window.sampling)
        r.window.open()
        #expect(r.looks.count == 1)  // the first look is at once, not a tick later
        steps(r, 30)  // a second
        #expect((3...5).contains(r.looks.count - 1), "\(r.looks.count - 1) looks in a second")  // about 4 Hz
        r.window.closeBubble()
        let n = r.looks.count
        steps(r, 90)
        #expect(r.looks.count == n && r.window.shadeTimer == nil)
    }

    @Test func theRectangleIsTheGlassOnTheScreenAndFollowsThePet() {
        let r = opened(0.0)
        defer { r.close() }
        let rect = r.looks[0], card = r.window.card
        #expect(r.frame.contains(rect) && rect.width == 328 && rect.height == card.frame.height - 6 - 9)
        #expect(rect.minX == r.frame.minX + 10 && rect.maxY == r.frame.maxY - 10)  // the window's 4 and the pane's 6 in from the top and the side
        r.window.move(to: Vec(300, 300))
        steps(r, 12)
        #expect(r.looks.last != rect && r.looks.last!.minX == r.frame.minX + 10 && r.looks.last!.maxY == r.frame.maxY - 10)
    }

    @Test func theFirstLookArrivesAtOnceNothingEasesFromTheSystemLook() {
        let r = opened(0.0)  // a dark backdrop: a light card
        defer { r.close() }
        #expect(r.window.shade.known && r.window.shade.level == 1 && r.window.shadeTimer == nil)
        #expect(Chrome.ink == 1 && r.window.card.glass.level == 1)
    }

    @Test func aDarkBackdropTurnsTheCardLightThroughSeveralFrames() {
        let r = opened(1.0)  // bright: a dark card, at rest
        defer { r.close() }
        #expect(Chrome.ink == 0 && r.window.card.glass.level == 0)
        r.backdrop = 0.0
        var levels: [Double] = [], glass: [Double?] = []
        for _ in 0..<60 {
            r.step()
            levels.append(r.window.shade.level)
            glass.append(r.window.card.glass.level)
        }
        #expect(Set(levels).count >= 5, "\(Set(levels).count) different levels")
        #expect(levels == levels.sorted() && levels.last == 1)  // up, never back
        #expect(glass.compactMap { $0 } == levels)  // the glass shows every level it is given
        #expect(Chrome.ink == 1 && r.window.shadeTimer == nil && r.window.card.glass.level == 1)  // arrived: the timer is gone
    }

    @Test func aBrightBackdropTurnsTheCardDark() {
        let r = opened(0.0)  // dark: a light card
        defer { r.close() }
        r.backdrop = 1.0
        var levels: [Double] = []
        var timers = 0
        for _ in 0..<60 {
            r.step()
            levels.append(r.window.shade.level)
            if r.window.shadeTimer != nil { timers += 1 }
        }
        #expect(Set(levels).count >= 5 && levels == levels.sorted(by: >) && levels.last == 0)
        #expect(Chrome.ink == 0 && r.window.shadeTimer == nil && timers > 5 && timers < 30)  // the 30 Hz timer ran for the turn only
    }

    @Test func theInkFlipsWithinAFrameOrTwoOfTheTurn() {
        let r = opened(1.0)
        defer { r.close() }
        r.backdrop = 0.0
        var inks: [Double] = []
        for _ in 0..<60 { r.step(); inks.append(Chrome.ink ?? -1) }
        #expect(inks.first! >= 0 && inks.last == 1 && inks == inks.sorted())
        #expect(inks.filter { $0 > 0 && $0 < 1 }.count <= 3)  // not a slow fade through a grey that reads on neither glass
    }

    @Test func aBackdropAroundTheMiddleKeepsWhatTheCardHas() {
        let r = opened(0.0)  // a light card
        defer { r.close() }
        for luma in [0.5, 0.45, 0.55, 0.42, 0.58] {
            r.backdrop = luma
            steps(r, 12)
            #expect(r.window.shade.level == 1 && r.window.shade.target == 1 && r.window.shadeTimer == nil, "luma \(luma)")
        }
        r.backdrop = 0.9
        steps(r, 60)
        #expect(r.window.shade.level == 0)
        for luma in [0.5, 0.57, 0.43] {
            r.backdrop = luma
            steps(r, 12)
            #expect(r.window.shade.level == 0, "luma \(luma)")  // and the dark card stays dark
        }
    }

    @Test func withoutAReadableBackdropTheCardFollowsTheSystemsMode() {
        for (dark, level) in [(true, 0.0), (false, 1.0)] {
            let r = Rig()
            defer { r.close() }
            r.systemDark = dark
            r.backdrop = nil
            r.window.open()
            steps(r, 60)
            // explicit either way (never the system's label colours on a glass that may have come out the other way round)
            #expect(!r.window.shade.known && Chrome.ink == level && r.window.card.glass.level == level && r.window.shadeTimer == nil, "dark \(dark)")
            #expect(r.looks.count > 3)  // it keeps looking: the permission may be granted
        }
    }

    @Test func theSystemsModeChangingIsFollowedWhileTheBackdropIsUnknown() {
        let r = Rig()
        defer { r.close() }
        r.backdrop = nil
        r.window.open()
        steps(r, 12)
        #expect(Chrome.ink == 0)  // dark mode: a dark card, light ink
        r.systemDark = false
        steps(r, 12)
        #expect(Chrome.ink == 1 && r.window.card.glass.level == 1)  // the next look picks up the light mode
    }

    @Test func aBackdropThatStopsBeingReadableGivesTheSystemsLookBackAfterAFewMisses() {
        let r = opened(0.0)
        defer { r.close() }
        #expect(Chrome.ink == 1)
        r.backdrop = nil
        steps(r, 90)
        #expect(!r.window.shade.known && Chrome.ink == 0 && r.window.card.glass.level == 0 && r.window.shadeTimer == nil)  // the rig's system is dark
        r.backdrop = 1.0  // and it is read again
        steps(r, 30)
        #expect(r.window.shade.known && Chrome.ink == 0)
    }

    @Test func reduceMotionGoesStraightToTheOtherLook() {
        let r = Rig()
        defer { r.close() }
        r.reduceMotion = true
        r.backdrop = 1.0
        r.window.open()
        r.backdrop = 0.0
        var levels = Set<Double>()
        var timer = false
        for _ in 0..<60 {
            r.step()
            levels.insert(r.window.shade.level)
            timer = timer || r.window.shadeTimer != nil
        }
        #expect(levels == [0, 1] && !timer && Chrome.ink == 1)  // no frame in between, no timer
    }

    @Test func theScreenAccessIsAskedForOncePerLaunchOnTheFirstCard() {
        let r = Rig()
        defer { r.close() }
        #expect(r.screenAsks == 0)
        r.window.open()
        #expect(r.screenAsks == 1)
        r.window.closeBubble(); r.window.open()
        r.window.open()
        r.window.closeBubble(); r.window.open()
        #expect(r.screenAsks == 1)
    }

    @Test func oneLookIsInFlightAtATimeAndTheNextOneWaitsForTheAnswer() {
        let r = Rig()
        defer { r.close() }
        r.holdLooks = true
        r.window.open()
        steps(r, 90)  // three seconds with the first look unanswered
        #expect(r.looks.count == 1 && r.window.sampling && !r.window.shade.known)
        r.answerLooks(0.0)
        #expect(!r.window.sampling && r.window.shade.known && Chrome.ink == 1)
        steps(r, 12)
        #expect(r.looks.count == 2 && r.window.sampling)  // the next one went out, and is again alone
        steps(r, 90)
        #expect(r.looks.count == 2)
    }

    @Test func anAnswerThatArrivesAfterTheCardClosedChangesNothing() {
        let r = Rig()
        defer { r.close() }
        r.holdLooks = true
        r.window.open()
        r.window.closeBubble()
        r.answerLooks(0.0)
        #expect(!r.window.sampling && !r.window.shade.known && Chrome.ink == nil && r.window.shadeTimer == nil)
    }

    @Test func closingTheCardMidTurnStopsTheTimerAndTheNextOpenGoesOn() {
        let r = opened(1.0)
        defer { r.close() }
        r.backdrop = 0.0
        while r.window.shadeTimer == nil && r.clock.now() < 1100 { r.step() }
        #expect(r.window.shadeTimer != nil && r.window.shade.moving)
        r.window.closeBubble()
        #expect(r.window.shadeTimer == nil)
        r.window.open()  // the look at once, and the turn goes on from where it was
        steps(r, 60)
        #expect(r.window.shade.level == 1 && Chrome.ink == 1 && r.window.shadeTimer == nil)
    }
}
