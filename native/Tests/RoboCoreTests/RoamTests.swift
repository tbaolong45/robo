// Port of tests/test_roam.py, plus the multi-monitor cases added with the Python fix.
import Foundation
import Testing
@testable import RoboCore

private let screen = Rect(0, 0, 1920, 1080)
private let screens = [screen]
private let rightScreen = Rect(1920, 0, 2560, 1440)  // an external monitor to the right, and taller
private let leftScreen = Rect(-2560, -180, 2560, 1440)  // or to the left, so x goes negative
private let both = [screen, rightScreen]
private let face = Vec(120, 120)
private let bubble = Vec(400, 300)
private let fps = 30.0
private let peak = 1.5 * Roam.speed  // smoothstep ease-in-out peaks at 1.5x the average speed
private let rounding = 1.5  // px: integer output can add up to ~sqrt(2) to a step
private let top = Vec(900, 0)  // far from the margin band, so the first drift is long

private struct Sample { let t: Double; let pos: IVec; var hop = false }  // hop: it was rebounding off a wall after this step

/// Step `r` at `fps` for `seconds` after t0.
private func run(_ r: Roamer, _ t0: Double, _ seconds: Double, asleep: Bool = false,
                 engaged: Bool = false, called: Bool = false, fps: Double = fps) -> [Sample] {
    (0..<Int(seconds * fps)).map { i in
        let t = t0 + Double(i + 1) / fps
        let pos = r.step(now: t, asleep: asleep, engaged: engaged, called: called)
        return Sample(t: t, pos: pos, hop: r.bouncing)
    }
}

/// Step an idle `r` at `fps` from t until it is in `mode`; return the time.
private func until(_ r: Roamer, _ t0: Double, _ mode: Roamer.Mode, limit: Double = 600) -> Double {
    var t = t0
    while r.mode != mode {
        t += 1 / fps
        #expect(t < limit, "never reached \(mode)")
        if t >= limit { break }
        _ = r.step(now: t, asleep: false, engaged: false)
    }
    return t
}

private func v(_ p: IVec) -> Vec { Vec(Double(p.x), Double(p.y)) }

/// Fully on the screen, or pinned to the top/left edge on an axis it cannot fit.
private func inside(_ pos: Vec, _ size: Vec, _ s: Rect) -> Bool {
    s.x <= pos.x && pos.x <= max(s.x, s.x + s.w - size.x)
        && s.y <= pos.y && pos.y <= max(s.y, s.y + s.h - size.y)
}

/// Every point of an n x n grid over the window (corners included) lies on some screen. Checked by
/// sampling, so it does not share fit()'s area arithmetic.
private func covered(_ pos: Vec, _ size: Vec, _ ss: [Rect], n: Int = 8) -> Bool {
    for i in 0...n {
        for j in 0...n {
            let x = pos.x + size.x * Double(i) / Double(n), y = pos.y + size.y * Double(j) / Double(n)
            if !ss.contains(where: { $0.x <= x && x <= $0.x + $0.w && $0.y <= y && y <= $0.y + $0.h }) { return false }
        }
    }
    return true
}

@Test func fitKeepsTheWindowInside() {
    #expect(fit(Vec(-50, -50), face, screens) == Vec(0, 0))
    #expect(fit(Vec(5000, 5000), face, screens) == Vec(1800, 960))
    #expect(fit(Vec(300, 400), face, screens) == Vec(300, 400))
}

@Test(arguments: [false, true])
func windowBiggerThanScreenIsPinnedTopLeft(asleep: Bool) {
    let r = Roamer(screens: [Rect(10, 20, 100, 80)], size: face, seed: 0)
    #expect(Set(run(r, 0, 200, asleep: asleep).map(\.pos)) == [IVec(10, 20)])
}

@Test(arguments: [false, true])
func presentFreezesMidDrift(asleep: Bool) {
    let r = Roamer(screens: screens, size: face, seed: 2, start: top)
    let t = until(r, 0, .drift) + 1
    _ = run(r, t - 1, 1)
    #expect(r.mode == .drift)
    let frozen = r.step(now: t, asleep: asleep, engaged: true)
    #expect(Set(run(r, t, 30, asleep: asleep, engaged: true).map(\.pos)) == [frozen])
    #expect(r.mode == .present)
}

@Test func presentSlidesTheBubbleOnScreen() {
    var r = Roamer(screens: screens, size: face, seed: 3, start: Vec(1800, 960))
    _ = r.step(now: 0, asleep: false, engaged: true)
    r.resize(bubble)
    let pos = r.step(now: 0.1, asleep: false, engaged: true)
    #expect(pos == IVec(1520, 780))
    #expect(Set(run(r, 0.1, 10, engaged: true).map(\.pos)) == [pos])

    r = Roamer(screens: screens, size: face, seed: 3, start: Vec(300, 200))
    r.resize(bubble)
    #expect(r.step(now: 0, asleep: false, engaged: true) == IVec(300, 200))
}

@Test(arguments: [
    (Vec(700, 300), Vec(leftEdge, topEdge)), (Vec(1100, 300), Vec(rightEdge, topEdge)),
    (Vec(700, 700), Vec(leftEdge, bottomEdge)), (Vec(1100, 700), Vec(rightEdge, bottomEdge)),
])
func sleepGlidesToTheNearestCornerAndStays(start: Vec, corner: Vec) {
    let r = Roamer(screens: screens, size: face, seed: 4, start: start)
    #expect(run(r, 0, 120, asleep: true).last?.pos == ivec(corner))
    #expect(r.mode == .sleep)
    #expect(Set(run(r, 120, 60, asleep: true).map(\.pos)) == [ivec(corner)])
}

@Test func withoutASpotItStartsInTheBottomRightCorner() {
    #expect(Roamer(screens: screens, size: face, seed: 4).pos == Vec(rightEdge, bottomEdge))
}

@Test func holdStaysPutThenWandersFromThere() {
    let r = Roamer(screens: screens, size: face, seed: 5)
    _ = r.step(now: 0, asleep: false, engaged: false)
    r.hold(now: 0, pos: Vec(500, 300))
    #expect(Set(run(r, 0, Roam.hold - 1, fps: 4).map(\.pos)) == [IVec(500, 300)])
    #expect(Set(run(r, Roam.hold - 1, 0.5, asleep: true, fps: 4).map(\.pos)) == [IVec(500, 300)])
    #expect(r.mode == .held)
    let path = run(r, Roam.hold, 120).map(\.pos)
    #expect(path.contains { $0 != IVec(500, 300) })
    #expect(dist(v(path[0]), Vec(500, 300)) <= 2)
}

@Test func holdIsClamped() {
    let r = Roamer(screens: screens, size: face, seed: 5)
    r.hold(now: 0, pos: Vec(5000, -40))
    #expect(r.step(now: 0, asleep: false, engaged: false) == IVec(1800, 0))
}

@Test func driftReachesItsTargetThenRests() {
    let r = Roamer(screens: screens, size: face, seed: 1)
    var t = until(r, 0, .drift)
    let goal = r.goal
    t = until(r, t, .rest)
    #expect(r.step(now: t, asleep: false, engaged: false)
        == IVec(Int(goal.x.rounded(.toNearestOrEven)), Int(goal.y.rounded(.toNearestOrEven))))
    let rested = until(r, t, .drift) - t
    #expect(Roam.rest.lowerBound <= rested && rested <= Roam.rest.upperBound + 2 / fps)
}

@Test func targetsLieOnAWall() {
    for s in [screen, Rect(-1280, 200, 1280, 1024)] {
        var rng = SplitMix64(seed: 0)
        let cx = s.x + s.w / 2, cy = s.y + s.h / 2
        var sides = Set<Int>()
        for _ in 0..<2000 {
            let p = pickTarget(&rng, s, face)
            #expect(inside(p, face, s))
            let gaps = [p.x - s.x, s.x + s.w - p.x - face.x, s.y + s.h - p.y - face.y]
            #expect(gaps.min()! < 1e-9)  // against the left, the right or the bottom wall
            #expect(!(p.x <= cx && cx <= p.x + face.x && p.y <= cy && cy <= p.y + face.y))
            for (i, g) in gaps.enumerated() where g < 1e-9 { sides.insert(i) }
        }
        #expect(sides == [0, 1, 2])
    }
}

// MARK: rebounding off a wall

@Test func theBounceIsTwoShrinkingHopsFromAndBackToTheWall() {
    #expect([-1, 0, Roam.bounceS / 2, Roam.bounceS, 5].allSatisfy { abs(Roam.bounce($0)) < 1e-9 })
    let hops = stride(from: 0.0, to: Roam.bounceS, by: 0.001).map { Roam.bounce($0) }
    #expect(hops.allSatisfy { $0 >= 0 && $0 <= Roam.bounceHeight })  // it never goes through the wall
    let first = hops[..<(hops.count / 2)].max()!, second = hops[(hops.count / 2)...].max()!
    #expect(first > 8 && first < Roam.bounceHeight)  // slight
    #expect(second > 0 && first > 2 * second)  // and each hop lower than the last
}

/// Drift until the pet has just stopped against a wall.
private func arrived(_ r: Roamer, _ t0: Double = 0) -> Double { until(r, until(r, t0, .drift), .rest) }

private func dot(_ a: Vec, _ b: Vec) -> Double { (a * b).sum() }

@Test(arguments: [UInt64](1...8))
func aDriftEndsOnAWallAndReboundsOffItBeforeSettling(seed: UInt64) {
    let r = Roamer(screens: screens, size: face, seed: seed)
    let t = arrived(r)
    let wall = r.pos, inward = r.wall
    #expect(wall.x == 0 || wall.x == 1800 || wall.y == 960)
    #expect(r.bouncing && abs(dist(inward, .zero) - 1) < 1e-9)
    let hops = run(r, t, Roam.bounceS + 0.2)
    let path = hops.map { v($0.pos) }
    let away = path.map { dot(inward, $0 - wall) }  // how far from the wall, along the way in
    #expect(away.allSatisfy { $0 >= -rounding })  // never through it
    #expect(away.max()! > 5 && away.max()! <= Roam.bounceHeight + rounding)  // a hop, and a slight one
    let rounded = IVec(Int(wall.x.rounded(.toNearestOrEven)), Int(wall.y.rounded(.toNearestOrEven)))
    #expect(hops.last?.pos == rounded && !r.bouncing && r.mode == .rest)  // and back on the wall to rest
    #expect(path.allSatisfy { inside($0, face, screen) })
    let quick = Roam.bounceHeight * (2 * .pi + 1) / Roam.bounceS  // the steepest part of the curve
    for (a, b) in zip(hops, hops.dropFirst()) { #expect(dist(v(a.pos), v(b.pos)) <= quick * (b.t - a.t) + rounding) }
    #expect(run(r, t + Roam.bounceS + 0.2, 5).allSatisfy { !$0.hop && $0.pos == hops.last?.pos })  // and then it is still
}

@Test func aPressMidReboundFreezesItAndTheReboundDoesNotResume() {
    let r = Roamer(screens: screens, size: face, seed: 1)
    let t = arrived(r)
    _ = run(r, t, 0.2)  // in the air
    let frozen = r.step(now: t + 0.2 + 1 / fps, asleep: false, engaged: true)
    #expect(!r.bouncing)  // the window's quick timer stops with it
    #expect(Set(run(r, t + 0.2 + 1 / fps, 2, engaged: true).map(\.pos)) == [frozen])
    #expect(Set(run(r, t + 2.3, 3).map(\.pos)) == [frozen])  // let go: it rests where it was left and does not hop on
}

/// The app moves the window while it rests (it keeps the face in place when the card opens or closes): a rebound that
/// is mid-hop then ends on the wall spot of the NEW place, not back where it touched the wall.
@Test func aMoveDuringTheReboundIsKept() {
    let r = Roamer(screens: screens, size: face, seed: 1)
    let t = arrived(r)
    _ = run(r, t, 0.2)
    let middle = Vec(screen.w - face.x, screen.h - face.y) / 2
    r.pos += (middle - r.pos) / dist(middle, r.pos) * 20  // 20 px toward the middle of the screen
    let expected = r.pos - r.wall * Roam.bounce(r.bounceT)  // where the hop would have put it down
    let last = run(r, t + 0.2, 1).last!.pos
    #expect(dist(v(last), expected) <= rounding && !r.bouncing)
}

@Test func aDropOrACallNextToAWallDoesNotRebound() {
    let r = Roamer(screens: screens, size: face, seed: 1)
    r.hold(now: 0, pos: Vec(0, 500))  // dropped against the left wall; the 10 minutes pass and it rests there, still
    #expect(Set(run(r, 0, Roam.hold + 10, fps: 4).map(\.pos)) == [IVec(0, 500)])
    let c = Roamer(screens: screens, size: face, seed: 1, start: Vec(700, 300))
    let corner = ivec(Vec(leftEdge, topEdge))  // Roam.edge in from both walls: a call stops short of them
    #expect(run(c, 0, 12, called: true).last?.pos == corner)
    #expect(Set(run(c, 12, 3, called: true).map(\.pos)) == [corner] && !c.bouncing)  // and nothing hops on arrival
}

@Test func neverFasterThanTheSpeedLimit() {
    let r = Roamer(screens: screens, size: face, seed: 6)
    let path = [Sample(t: 0, pos: r.step(now: 0, asleep: false, engaged: false))] + run(r, 0, 600)
    for (a, b) in zip(path, path.dropFirst()) where !a.hop && !b.hop {  // a rebound off a wall is quicker, and checked on its own
        #expect(dist(v(a.pos), v(b.pos)) <= peak * (b.t - a.t) + rounding)
    }
    #expect(Set(path.map(\.pos)).count > 100)
}

@Test func aLongGapMovesAtMostOneCappedFrame() {
    let r = Roamer(screens: screens, size: face, seed: 7, start: top)
    let t = until(r, 0, .drift) + 0.5
    let a = r.step(now: t, asleep: false, engaged: false)
    #expect(r.mode == .drift)
    let b = r.step(now: t + 3600, asleep: false, engaged: false)
    #expect(dist(v(a), v(b)) <= peak * Roam.maxDT + rounding)
}

@Test func sameSeedSamePath() {
    func path(_ seed: UInt64) -> [IVec] {
        run(Roamer(screens: screens, size: face, seed: seed), 0, 300).map(\.pos)
    }
    #expect(path(9) == path(9))
    #expect(path(9) != path(10))
}

@Test func resizeAndANewScreenKeepItOnScreen() {
    let r = Roamer(screens: screens, size: face, seed: 11, start: Vec(1800, 960))
    r.resize(bubble)
    #expect(r.step(now: 0, asleep: false, engaged: false) == IVec(1520, 780))
    r.setScreens([Rect(0, 0, 1280, 720)])
    #expect(r.step(now: 0.1, asleep: false, engaged: false) == IVec(880, 420))
}

@Test func anHourOfJitteryFramesNeverLeavesTheScreen() {
    var rng = SplitMix64(seed: 0)
    let layouts = [screen, Rect(-1280, 200, 1280, 1024), Rect(0, 0, 200, 150)]
    let r = Roamer(screens: screens, size: face, seed: 12)
    let gaps: [Double] = Array(repeating: 1 / fps, count: 30) + [0, 0.5, 5]
    var t = 0.0
    while t < 3600 {
        t += gaps.randomElement(using: &rng)!
        let engaged = Int(t / 90) % 5 == 0
        let size = engaged ? bubble : face
        if size != r.size { r.resize(size) }
        let s = layouts[min(Int(t / 1200), 2)]
        if r.screens != [s] { r.setScreens([s]) }
        if Double.random(in: 0..<1, using: &rng) < 0.0005 {
            r.hold(now: t, pos: Vec(uniform(-500, 3000, &rng), uniform(-500, 3000, &rng)), seconds: 60)
        }
        let pos = r.step(now: t, asleep: Int(t / 300) % 4 == 3, engaged: engaged)
        #expect(r.pos.x.isFinite && r.pos.y.isFinite)
        #expect(inside(v(pos), size, s))
    }
}

// MARK: several screens

@Test func fitAcrossScreens() {
    let deadCorner = [screen, Rect(1920, 400, 2560, 1440)]
    let cases: [([Rect], Vec, Vec)] = [
        (both, Vec(2500, 300), Vec(2500, 300)),  // on the second screen
        (both, Vec(1860, 300), Vec(1860, 300)),  // straddling the border with both halves on screen
        (both, Vec(9000, 300), Vec(4360, 300)),  // past the far edge: onto the nearest screen
        ([leftScreen, screen], Vec(-3000, 100), Vec(-2560, 100)),  // a monitor on the left, negative x
        (deadCorner, Vec(1860, 100), Vec(1800, 100)),  // half over a dead corner
    ]
    for (ss, pos, want) in cases {
        let got = fit(pos, face, ss)
        #expect(got == want && covered(got, face, ss), "\(pos) -> \(got), wanted \(want)")
    }
}

@Test func aDropOnTheSecondScreenStays() {
    let r = Roamer(screens: both, size: face, seed: 5)
    r.hold(now: 0, pos: Vec(3000, 500))
    #expect(r.step(now: 0, asleep: false, engaged: false) == IVec(3000, 500))
}

@Test func itSleepsInTheNearestCornerOfTheScreenItIsOn() {
    let r = Roamer(screens: both, size: face, seed: 4, start: Vec(3000, 500))
    let last = run(r, 0, 200, asleep: true).last?.pos  // the right screen's top-left, not the main screen's corner
    #expect(last == IVec(Int(rightScreen.x + Roam.edge), Int(rightScreen.y + Roam.edge)))
}

@Test func itWandersOntoEveryScreenAndNeverOffThem() {
    let r = Roamer(screens: both, size: face, seed: 1)
    var seen = Set<Int>()
    for s in run(r, 0, 3600) {
        let pos = v(s.pos)
        #expect(covered(pos, face, both))
        let cx = pos.x + face.x / 2, cy = pos.y + face.y / 2
        for (i, sc) in both.enumerated() where sc.x <= cx && cx < sc.x + sc.w && sc.y <= cy && cy < sc.y + sc.h {
            seen.insert(i)
        }
    }
    #expect(seen == [0, 1])
}

@Test func unpluggingItsScreenBringsItBackToTheOneLeft() {
    let r = Roamer(screens: both, size: face, seed: 6, start: Vec(3000, 500))
    r.setScreens([screen])
    #expect(r.step(now: 0, asleep: false, engaged: false) == IVec(1800, 500))
}

// MARK: - called: it walks to the nearest corner of its screen instead of freezing mid-drift

private let leftEdge = Roam.edge, topEdge = Roam.edge
private let rightEdge = 1920 - 120 - Roam.edge, bottomEdge = 1080 - 120 - Roam.edge
private func ivec(_ p: Vec) -> IVec { IVec(Int(p.x), Int(p.y)) }

@Test(arguments: [
    (Vec(700, 300), Vec(leftEdge, topEdge)), (Vec(1100, 300), Vec(rightEdge, topEdge)),
    (Vec(700, 700), Vec(leftEdge, bottomEdge)), (Vec(1100, 700), Vec(rightEdge, bottomEdge)),
])
func calledWalksToTheNearestCornerAtCallSpeedAndStays(start: Vec, corner: Vec) {
    let r = Roamer(screens: screens, size: face, seed: 1, start: start)
    let trip = dist(start, corner) / Roam.callSpeed
    _ = run(r, 0, trip - 1, called: true)
    #expect(r.pos != corner && r.mode == .come)
    #expect(run(r, trip - 1, 2.5, called: true).last?.pos == ivec(corner))  // on time, not at drift speed
    #expect(Set(run(r, trip + 1.5, 30, called: true).map(\.pos)) == [ivec(corner)])
}

@Test func itsEyesLeadTheWayToTheCorner() {
    let r = Roamer(screens: screens, size: face, seed: 1, start: Vec(700, 300))
    _ = run(r, 0, 0.5, called: true)
    #expect(r.heading == -1)
}

@Test func pressingItFreezesTheWalk() {
    let r = Roamer(screens: screens, size: face, seed: 1, start: Vec(700, 300))
    _ = run(r, 0, 1, called: true)
    let frozen = r.step(now: 1, asleep: false, engaged: true, called: true)
    #expect(Set(run(r, 1, 5, engaged: true, called: true).map(\.pos)) == [frozen])
    #expect(r.mode == .present)
}

@Test func aStayWinsOverACall() {
    let r = Roamer(screens: screens, size: face, seed: 5)
    r.hold(now: 0, pos: Vec(500, 300), seconds: 1e9)  // the menu's Stay
    #expect(r.stays(now: 0))
    #expect(Set(run(r, 0, 20, called: true).map(\.pos)) == [IVec(500, 300)] && r.mode == .held)
    #expect(Set(run(r, Roam.hold, 20, called: true).map(\.pos)) == [IVec(500, 300)])  // even after a drop's 600 s
    r.hold(now: Roam.hold + 20, pos: Vec(500, 300), seconds: 0)  // Wander
    #expect(!r.stays(now: Roam.hold + 20))
    #expect(run(r, Roam.hold + 20, 20, called: true).last?.pos == ivec(Vec(leftEdge, topEdge)))
}

@Test func aCallWinsOverADropAndEndsItsHold() {
    let r = Roamer(screens: screens, size: face, seed: 5)
    r.hold(now: 0, pos: Vec(500, 300))
    #expect(!r.stays(now: 0))  // a drop is not a Stay
    #expect(run(r, 0, 20, called: true).last?.pos == ivec(Vec(leftEdge, topEdge)) && r.mode == .come)
    #expect(r.heldUntil < 0)  // so the corner is not the old spot held for 10 minutes
}

@Test func afterACallOnADropItRestsInTheCornerThenDriftsOn() {
    let r = Roamer(screens: screens, size: face, seed: 1)
    r.hold(now: 0, pos: Vec(500, 300))
    let corner = ivec(Vec(leftEdge, topEdge))
    #expect(run(r, 0, 10, called: true).last?.pos == corner)
    #expect(Set(run(r, 10, Roam.rest.lowerBound - 1).map(\.pos)) == [corner] && r.mode == .rest)
    #expect(run(r, 10 + Roam.rest.lowerBound - 1, Roam.rest.upperBound + 10).contains { $0.pos != corner })  // not held 590 s more
}

// A window as tall as the card, on a 1920x1080 screen with a taller one to its left (unequal sizes, negative x).
private let card = Vec(348, 420)
private let pair = [leftScreen, screen]

/// The corner of `s` the pet waits in: `Roam.edge` in from the given sides.
private func corner(_ s: Rect, right: Bool, bottom: Bool, _ size: Vec = card) -> Vec {
    Vec(right ? s.x + s.w - size.x - Roam.edge : s.x + Roam.edge, bottom ? s.y + s.h - size.y - Roam.edge : s.y + Roam.edge)
}

/// Where a drop at `spot` goes when called: the nearest of the four corners of the screen it is on.
private let drops: [(Vec, Vec)] = [
    (Vec(100, 100), corner(screen, right: false, bottom: false)), (Vec(1400, 90), corner(screen, right: true, bottom: false)),
    (Vec(60, 560), corner(screen, right: false, bottom: true)), (Vec(1500, 600), corner(screen, right: true, bottom: true)),
    (Vec(780, 325), corner(screen, right: false, bottom: false)), (Vec(790, 335), corner(screen, right: true, bottom: true)),  // either side of the middle
    (Vec(-2000, 0), corner(leftScreen, right: false, bottom: false)), (Vec(-600, -100), corner(leftScreen, right: true, bottom: false)),
    (Vec(-2400, 700), corner(leftScreen, right: false, bottom: true)), (Vec(-700, 500), corner(leftScreen, right: true, bottom: true)),
]

@Test(arguments: drops)
func aCallAfterADropGoesToTheNearestOfTheFourCorners(spot: Vec, corner: Vec) {
    let r = Roamer(screens: pair, size: card, seed: 1)
    r.hold(now: 0, pos: spot)
    #expect(r.pos == spot)  // a drop that fits is not moved
    _ = r.step(now: 0.1, asleep: false, engaged: false, called: true)
    #expect(r.goal == corner && r.mode == .come)  // aimed at once, from the spot it was dropped on
    #expect(run(r, 0.1, 20, called: true).last?.pos == ivec(corner))
}

@Test(arguments: drops)
func aSleeperAfterADropGoesToTheNearestOfTheFourCorners(spot: Vec, corner: Vec) {
    let r = Roamer(screens: pair, size: card, seed: 1)
    r.hold(now: 0, pos: spot)
    #expect(Set(run(r, 0, Roam.hold - 1, asleep: true, fps: 4).map(\.pos)) == [ivec(spot)] && r.mode == .held)
    #expect(run(r, Roam.hold, 120, asleep: true).last?.pos == ivec(corner) && r.mode == .sleep)
}

@Test func afterACallItRestsInTheCornerThenDriftsOn() {
    let r = Roamer(screens: screens, size: face, seed: 1, start: Vec(700, 300))
    let corner = ivec(Vec(leftEdge, topEdge))
    #expect(run(r, 0, 10, called: true).last?.pos == corner)
    #expect(Set(run(r, 10, Roam.rest.lowerBound - 1).map(\.pos)) == [corner] && r.mode == .rest)
    #expect(run(r, 10 + Roam.rest.lowerBound - 1, Roam.rest.upperBound + 10).contains { $0.pos != corner })
}

@Test func theCornerIsOneOfTheScreenItIsOn() {
    let main = Rect(0, 0, 2560, 1440), builtIn = Rect(-1800, 271, 1800, 1169)
    let r = Roamer(screens: [main, builtIn], size: face, seed: 1, start: Vec(-1700, 500))
    #expect(run(r, 0, 30, called: true).last?.pos == IVec(-1800 + Int(Roam.edge), 271 + Int(Roam.edge)))
}

@Test func aCallWinsOverSleep() {
    let r = Roamer(screens: screens, size: face, seed: 1, start: Vec(700, 300))  // both go top-left: only the pace tells
    #expect(run(r, 0, 10, asleep: true, called: true).last?.pos == ivec(Vec(leftEdge, topEdge)))  // 730 px: 3 s called, 18 s asleep
    #expect(r.mode == .come)
}

@Test func aBiggerWindowReAimsTheWalk() {
    let r = Roamer(screens: screens, size: face, seed: 1, start: Vec(1100, 700))
    _ = run(r, 0, 1, called: true)
    r.resize(bubble)
    #expect(run(r, 1, 20, called: true).last?.pos == IVec(1920 - 400 - Int(Roam.edge), 1080 - 300 - Int(Roam.edge)))
}
