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

private struct Sample { let t: Double; let pos: IVec }

/// Step `r` at `fps` for `seconds` after t0.
private func run(_ r: Roamer, _ t0: Double, _ seconds: Double, asleep: Bool = false,
                 engaged: Bool = false, fps: Double = fps) -> [Sample] {
    (0..<Int(seconds * fps)).map { i in
        let t = t0 + Double(i + 1) / fps
        return Sample(t: t, pos: r.step(now: t, asleep: asleep, engaged: engaged))
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

@Test func sleepGlidesToTheBottomRightCornerAndStays() {
    let r = Roamer(screens: screens, size: face, seed: 4, start: Vec(0, 0))
    let bed = IVec(1920 - 120 - Int(Roam.edge), 1080 - 120 - Int(Roam.edge))
    #expect(run(r, 0, 120, asleep: true).last?.pos == bed)
    #expect(r.mode == .sleep)
    #expect(Set(run(r, 120, 60, asleep: true).map(\.pos)) == [bed])
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

@Test func targetsLieInTheMarginBand() {
    for s in [screen, Rect(-1280, 200, 1280, 1024)] {
        var rng = SplitMix64(seed: 0)
        let cx = s.x + s.w / 2, cy = s.y + s.h / 2
        var sides = Set<Int>()
        for _ in 0..<2000 {
            let p = pickTarget(&rng, s, face)
            #expect(inside(p, face, s))
            let gaps = [p.x - s.x, s.x + s.w - p.x - face.x, s.y + s.h - p.y - face.y]
            #expect(gaps.min()! <= Roam.margin)
            #expect(!(p.x <= cx && cx <= p.x + face.x && p.y <= cy && cy <= p.y + face.y))
            for (i, g) in gaps.enumerated() where g <= Roam.margin { sides.insert(i) }
        }
        #expect(sides == [0, 1, 2])
    }
}

@Test func neverFasterThanTheSpeedLimit() {
    let r = Roamer(screens: screens, size: face, seed: 6)
    let path = [Sample(t: 0, pos: r.step(now: 0, asleep: false, engaged: false))] + run(r, 0, 600)
    for (a, b) in zip(path, path.dropFirst()) {
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

@Test func itSleepsInTheCornerOfTheScreenItIsOn() {
    let r = Roamer(screens: both, size: face, seed: 4, start: Vec(3000, 500))
    let last = run(r, 0, 200, asleep: true).last?.pos
    #expect(last == IVec(Int(rightScreen.x + rightScreen.w) - 120 - Int(Roam.edge),
                         Int(rightScreen.y + rightScreen.h) - 120 - Int(Roam.edge)))
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
