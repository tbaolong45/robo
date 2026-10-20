// Port of tests/test_look.py: where robo's eyes point (at the cursor while it moves, along its walk,
// else free glances), plus golden values from the Python `look_at` and animator.
// Not ported: test_the_widget_hands_the_look_to_the_animator (it needs FaceWidget/QApplication).
import Foundation
import Testing
@testable import RoboCore

private let centre = Vec(500, 500)

private func settle(_ anim: Animator, _ goal: FaceParams, _ look: Vec?, secs: Double = 1.5, dt: Double = 1.0 / 30) -> FaceParams {
    var t = 0.0, p = goal
    while t < secs {
        t += dt
        p = anim.step(goal, dt: dt, talking: false, now: t, look: look)
    }
    return p
}

@Suite("Look", .timeLimit(.minutes(1)))
struct LookTests {
    @Test func eyesPointTowardTheCursor() {
        let right = lookAt(centre: centre, cursor: Vec(900, 500), stillFor: 0)!
        let above = lookAt(centre: centre, cursor: Vec(500, 100), stillFor: 0)!
        #expect(right.x > 0.3 && abs(right.y) < 1e-9)
        #expect(above.y < -0.3 && abs(above.x) < 1e-9)
    }

    @Test func aNearCursorLooksLessThanAFarOneAndItCaps() {
        func pull(_ cursor: Vec) -> Double {
            let v = lookAt(centre: centre, cursor: cursor, stillFor: 0)!
            return hypot(v.x, v.y)
        }
        let near = pull(Vec(540, 500)), far = pull(Vec(900, 500)), gone = pull(Vec(5000, 5000))
        #expect(0 < near && near < far && far < gone)
        #expect(abs(gone - Look.gain) <= 1e-6 * Look.gain)
    }

    @Test func aCursorOnTheFaceGivesNoPull() {
        #expect(lookAt(centre: centre, cursor: centre, stillFor: 0) == Vec(0, 0))
    }

    @Test func aStillCursorIsForgottenThenTheWalkDecides() {
        let cursor = Vec(900, 500)
        #expect(lookAt(centre: centre, cursor: cursor, stillFor: Look.stale) == nil)
        #expect(lookAt(centre: centre, cursor: cursor, stillFor: Look.stale, heading: -1)!.x < 0)
        #expect(lookAt(centre: centre, cursor: cursor, stillFor: Look.stale, heading: 1)!.x > 0)
    }

    @Test func aMovingCursorBeatsTheWalk() {
        #expect(lookAt(centre: centre, cursor: Vec(900, 500), stillFor: 0, heading: -1)!.x > 0)
    }

    @Test func idleEyesFollowTheLookAndFreeGlancesStaySmall() {
        let idle = FaceParams.target(.idle, "neutral")
        #expect(settle(Animator(seed: 1), idle, Vec(0.9, 0)).gazeX > 0.7)
        #expect(abs(settle(Animator(seed: 1), idle, nil).gazeX) <= 0.36)
    }

    @Test func aThinkingFaceKeepsItsOwnGaze() {
        let thinking = FaceParams.target(.thinking, "neutral")
        let p = settle(Animator(seed: 1), thinking, Vec(-0.9, 0))
        #expect(abs(p.gazeX - thinking.gazeX) <= 0.05)
    }

    @Test func noLookChangesNothing() {
        let idle = FaceParams.target(.idle, "neutral")
        let a = Animator(seed: 5), b = Animator(seed: 5)
        for i in 1..<200 {
            let now = Double(i) / 60
            #expect(a.step(idle, dt: 1.0 / 60, talking: false, now: now)
                == b.step(idle, dt: 1.0 / 60, talking: false, now: now, look: nil))
        }
    }

    @Test(arguments: [(Vec(100, 900), Vec(900, 900), 1), (Vec(900, 900), Vec(100, 900), -1)])
    func headingFollowsADriftAndIsZeroAtRest(start: Vec, goal: Vec, want: Int) {
        let r = Roamer(screens: [Rect(0, 0, 1920, 1080)], size: Vec(120, 120), seed: 1, start: start)
        #expect(r.heading == 0)  // resting before the first drift
        r.pos = start  // Python also reset origin and called _go(goal); heading only reads pos, goal and mode
        r.goal = goal
        r.mode = .drift
        #expect(r.heading == want)
        r.mode = .rest
        #expect(r.heading == 0)
    }

    // MARK: golden parity with Python

    // look_at(centre (500, 500), cursor, still_s, heading), printed with "%.13g"
    @Test func lookAtMatchesPython() {
        let golden: [(Vec, Double, Int, Vec?)] = [
            (Vec(900, 500), 0, 0, Vec(0.72, 0)),
            (Vec(500, 100), 0, 0, Vec(0, -0.72)),
            (Vec(540, 500), 0, 0, Vec(0.072, 0)),
            (Vec(5000, 5000), 0, 0, Vec(0.6363961030679, 0.6363961030679)),
            (Vec(612.3, 777.7), 3.0, 1, Vec(0.20214, 0.49986)),
            (Vec(500, 500), 0, 0, Vec(0, 0)),
            (Vec(100, 900), 14.99, -1, Vec(-0.6363961030679, 0.6363961030679)),
            (Vec(900, 500), 15, 0, nil),
            (Vec(900, 500), 15, -1, Vec(-0.6, 0)),
            (Vec(900, 500), 15, 1, Vec(0.6, 0)),
        ]
        for (cursor, still, heading, want) in golden {
            let got = lookAt(centre: centre, cursor: cursor, stillFor: still, heading: heading)
            if let want, let got {
                #expect(abs(got.x - want.x) <= 1e-9 && abs(got.y - want.y) <= 1e-9, "\(cursor) \(still) \(heading): \(got) vs \(want)")
            } else {
                #expect(got == nil && want == nil, "\(cursor) \(still) \(heading): \(String(describing: got))")
            }
        }
    }

    /// The eyes follow a look for 100 frames, free-glance for 100, then follow another.
    @Test func lookTraceMatchesPython() {
        let idle = FaceParams.target(.idle, "neutral")
        let frames = goldenFrames(300, dt: 1.0 / 30, target: { _ in idle },
                                  look: { $0 <= 100 ? Vec(0.9, 0) : $0 <= 200 ? nil : Vec(-0.4, 0.3) })
        expectTrace("look", Animator(seed: 5), frames, [
            (1, [1, 1, 0.55, 0.07224240743957, 0, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 0.05233595624294], ""),
            (15, [1, 1, 0.55, 0.893434449848, 0, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 0.7071067811865], ""),
            (100, [1, 1, 0.55, 0.9, 0, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, -0.8660254037844], ""),
            (101, [1, 1, 0.55, 0.8514874171568, -0.015122576089, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, -0.8386705679454], ""),
            (150, [1, 1, 0.55, 0.2956274987471, -0.1883979083495, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 1], ""),
            (200, [1, 1, 0.55, 0.249755404989, -0.1047885215905, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, -0.8660254037844], ""),
            (201, [1, 1, 0.55, 0.1770482023525, -0.03483746407998, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, -0.8910065241884], ""),
            (300, [1, 1, 0.55, -0.4, 0.3, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 6.123233995737e-16], ""),
        ], sums: [300, 294.782420725952, 165, 80.6944566201885, 10.7219272362063, 0, 0, 0, 0, 0, 44.9999999999998, 0, 300, 56400, 254.999999999999, 240.000000000001, 300, 38.1884592970256])
    }
}
