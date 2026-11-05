// The pet's life (the eyes, the moods, the card closing): see AppTests.swift for the helpers.
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
@testable import RoboUI

// MARK: - alive: the eyes follow the pointer, and a bored robo fidgets

@MainActor @Suite(.serialized) struct AliveTests {
    @Test func theEyesFollowAMovingPointerThenForgetAStillOne() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        let c = r.faceMiddle
        r.pointer = CGPoint(x: c.x + 600, y: c.y)  // far to the right
        w.tick()
        #expect((w.face.look?.x ?? 0) > 0.5)  // it moved, so robo looks
        r.clock.advance(Look.stale + 1)  // ...but a pointer that stopped long ago is old news
        w.tick()
        #expect(w.face.look == nil)  // robo is at rest: free glances
    }

    @Test func theEyesLeadTheWayWhileItWalks() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        w.tick()
        r.clock.advance(Look.stale + 1)  // the pointer has not moved for a while
        w.roamer.mode = .drift
        w.roamer.goal = w.roamer.pos - Vec(500, 0)
        w.tick()
        #expect((w.face.look?.x ?? 0) < 0)
    }

    @Test func theLookUsesTheFaceWhereverItIsOnTheMainDisplay() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        r.window.refit()
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(900, 700))  // away from the corner, on the main display
        r.window.move(to: r.window.roamer.pos)
        let c = r.faceMiddle
        r.pointer = CGPoint(x: c.x - 400, y: c.y)  // left of the face
        r.window.tick()
        #expect((r.window.face.look?.x ?? 0) < -0.3)
        r.pointer = CGPoint(x: c.x + 400, y: c.y)  // right of it: the y-down maths agree
        r.window.tick()
        #expect((r.window.face.look?.x ?? 0) > 0.3)
        r.pointer = CGPoint(x: c.x, y: c.y + 400)  // above it on screen
        r.window.tick()
        #expect((r.window.face.look?.y ?? 0) < -0.3)
    }

    @Test func aBoredRoboNowAndThenShowsAMood() async {
        let r = Rig()
        defer { r.close() }
        r.window.fidgetAt = 0
        r.window.tick()
        #expect(RoboWindow.fidgets.contains(r.window.mind.emotion))
        #expect(r.window.fidgetAt > r.clock.now() + 30)  // and it is a while until the next one
    }

    @Test func aBusyOrTalkedToRoboDoesNotFidget() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        w.busy = true
        w.fidgetAt = 0
        w.tick()
        #expect(w.mind.emotion == "neutral")
        w.busy = false
        w.fidgetAt = 0
        w.open()  // the card is up: the user is reading
        w.tick()
        #expect(w.mind.emotion == "neutral")
    }

    @Test func theCardClosesByItselfWhenItsTimeIsUpUnlessTheMouseIsOverIt() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        w.open(closeAfter: 20)
        w.closeAt = r.clock.now() - 1  // the reply's time is up
        w.tick()
        #expect(w.card.isHidden && r.frame.size == CGSize(width: 136, height: 136))
        w.open()
        w.closeAt = r.clock.now() - 1
        w.busy = true  // a run is going: the card stays
        w.tick()
        #expect(!w.card.isHidden)
    }
}

