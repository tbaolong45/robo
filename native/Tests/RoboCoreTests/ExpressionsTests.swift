// Port of the non-Qt parts of tests/test_face.py (expression table and animator), plus golden
// parity with the Python implementation. The golden numbers come from the Python code itself
// (scratch script: import robo.face.{expressions,animator}, run `Animator(seed)` over the same
// frames and print "%.13g"); the Swift animator reuses Python's Mersenne Twister, so one seed gives
// the same blinks and glances.
// Not ported (they need QPainter/QWidget, so they belong to the UI port): widget renders
// offscreen, frame interval follows activity, set_state timer, glow antialiasing, theme hooks.
import Foundation
import Testing
@testable import RoboCore

private let numbers: [FaceKey] = FaceParams.floats + [\.bob]  // test_face.py's FLOATS: every field but effects
private let names = ["eyeW", "eyeH", "eyeRound", "gazeX", "gazeY", "lidTop", "lidAngle", "lidBottom", "skew",
                     "wink", "mouthCurve", "mouthOpen", "mouthW", "hue", "sat", "glow", "wander", "bob"]

/// Rough visual distance; hue counts per 60 degrees, effects count 1 each.
private func dist(_ a: FaceParams, _ b: FaceParams) -> Double {
    let d = numbers.filter { $0 != \FaceParams.hue }.reduce(0.0) { $0 + abs(a[keyPath: $1] - b[keyPath: $1]) }
    return d + abs(a.hue - b.hue) / 60 + Double(a.effects.symmetricDifference(b.effects).count)
}

private func runFrames(_ anim: Animator, _ tgt: FaceParams, _ secs: Double, dt: Double = 1.0 / 60,
                       talking: Bool = false, t0: Double = 0) -> [(t: Double, p: FaceParams)] {
    var out: [(t: Double, p: FaceParams)] = []
    var t = t0
    for _ in 0..<Int(secs / dt) {
        t += dt
        out.append((t, anim.step(tgt, dt: dt, talking: talking, now: t)))
    }
    return out
}

private func approx(_ a: Double, _ b: Double, abs tol: Double? = nil) -> Bool {
    abs(a - b) <= (tol ?? max(1e-6 * abs(b), 1e-12))
}

// MARK: golden parity helpers (shared with LookTests)

typealias GoldenRow = (frame: Int, values: [Double], fx: String)

struct GoldenFrame {
    var target: FaceParams
    var dt: Double
    var talking = false
    var now: Double
    var look: Vec?
}

/// Frames `1...n` at `t0 + i * dt`, the way the Python script built them.
func goldenFrames(_ n: Int, dt: Double, t0: Double = 0, target: (Int) -> FaceParams,
                  talking: (Int) -> Bool = { _ in false }, look: (Int) -> Vec? = { _ in nil }) -> [GoldenFrame] {
    (1...n).map { GoldenFrame(target: target($0), dt: dt, talking: talking($0), now: t0 + Double($0) * dt, look: look($0)) }
}

/// Step `anim` over `frames` and compare the sampled frames (1e-9) and the per-field sums over the
/// whole trace (1e-9 relative) with what Python produced. Sums cover every frame, so a single
/// frame's blink landing differently would show.
func expectTrace(_ name: String, _ anim: Animator, _ frames: [GoldenFrame], _ rows: [GoldenRow], sums: [Double]) {
    var total = [Double](repeating: 0, count: numbers.count)
    let want = Dictionary(uniqueKeysWithValues: rows.map { ($0.frame, $0) })
    for (i, f) in frames.enumerated() {
        let p = anim.step(f.target, dt: f.dt, talking: f.talking, now: f.now, look: f.look)
        let got = numbers.map { p[keyPath: $0] }
        for (k, v) in got.enumerated() { total[k] += v }
        guard let row = want[i + 1] else { continue }
        for k in got.indices {
            #expect(abs(got[k] - row.values[k]) <= 1e-9, "\(name) frame \(row.frame) \(names[k]): \(got[k]) vs \(row.values[k])")
        }
        #expect(p.effects.sorted().joined(separator: " ") == row.fx, "\(name) frame \(row.frame) effects")
    }
    for k in total.indices {
        #expect(abs(total[k] - sums[k]) <= 1e-9 * max(1, abs(sums[k])), "\(name) sum of \(names[k]): \(total[k]) vs \(sums[k])")
    }
}

@Suite("Expressions and animator", .timeLimit(.minutes(1)))
struct ExpressionsTests {
    // MARK: expression table

    @Test(arguments: Activity.allCases, emotions)
    func targetIsTotalAndInRange(activity: Activity, emotion: String) {
        let p = FaceParams.target(activity, emotion)
        #expect(numbers.allSatisfy { p[keyPath: $0].isFinite })
        #expect((0...1).contains(p.lidTop) && (0...1).contains(p.lidBottom) && (0...1).contains(p.mouthOpen))
        #expect((-1...1).contains(p.mouthCurve) && p.eyeW > 0 && p.eyeH > 0)
    }

    // An unknown activity name cannot be built (Activity is an enum), so only the emotion can fall back.
    @Test func unknownEmotionFallsBack() {
        #expect(FaceParams.target(.idle, "nope") == FaceParams.target(.idle, "neutral"))
    }

    @Test(arguments: emotions.dropFirst())
    func eachEmotionReadsDifferentlyFromNeutral(emotion: String) {
        #expect(dist(FaceParams.target(.idle, emotion), FaceParams.target(.idle, "neutral")) > 0.8)
    }

    @Test(arguments: Activity.allCases.dropFirst())
    func eachActivityDiffersFromIdle(activity: Activity) {
        #expect(dist(FaceParams.target(activity, "neutral"), FaceParams.target(.idle, "neutral")) > 0.5)
    }

    @Test func emotionsArePairwiseDistinct() {
        let ps = emotions.map { FaceParams.target(.idle, $0) }
        let closest = ps.indices.flatMap { i in ps[(i + 1)...].map { dist(ps[i], $0) } }.min()!
        #expect(closest > 0.5)
    }

    @Test func happySmilesSadFrowns() {
        #expect(FaceParams.target(.idle, "happy").mouthCurve > 0.4)
        #expect(0.4 > FaceParams.target(.idle, "sad").mouthCurve + 0.8)
    }

    @Test func asleepOverridesEmotion() {
        #expect(FaceParams.target(.asleep, "happy") == FaceParams.target(.asleep, "sad"))
        #expect(FaceParams.target(.asleep, "neutral").effects.contains("zzz"))
    }

    // MARK: animator

    @Test func convergesToTarget() {
        let a = Animator(seed: 1)
        _ = a.step(FaceParams.target(.idle, "neutral"), dt: 1.0 / 60, talking: false, now: 0)
        let goal = FaceParams.target(.working, "sad")  // no wander, so gaze should settle exactly
        let p = runFrames(a, goal, 1.5).last!.p
        // Sample just after the frame so a blink can't be mid-flight.
        for (k, n) in zip(numbers, names) where n != "eyeH" && n != "bob" {
            #expect(approx(p[keyPath: k], goal[keyPath: k], abs: 0.02), "\(n)")
        }
        #expect(p.effects == goal.effects)
    }

    @Test func effectsSwitchInstantly() {
        let a = Animator(seed: 1)
        _ = a.step(FaceParams.target(.idle, "neutral"), dt: 1.0 / 60, talking: false, now: 0)
        #expect(a.step(FaceParams.target(.idle, "confused"), dt: 1.0 / 60, talking: false, now: 0.02).effects == ["question"])
    }

    @Test func blinkHappensAndIsQuick() {
        let goal = FaceParams.target(.working, "neutral")
        let frames = runFrames(Animator(seed: 3), goal, 7.0, dt: 1.0 / 120)
        let shut = frames.filter { $0.p.eyeH < 0.5 * goal.eyeH }.map(\.t)
        #expect(!shut.isEmpty && shut[0] < 6.5)
        let first = shut.filter { $0 - shut[0] < 1.0 }
        #expect(first.last! - first.first! < 0.3)
    }

    @Test func noBlinkWhileAsleep() {
        let goal = FaceParams.target(.asleep, "neutral")
        let frames = runFrames(Animator(seed: 3), goal, 10.0).dropFirst(60)
        #expect(frames.allSatisfy { abs($0.p.eyeH - goal.eyeH) < 0.05 })
    }

    @Test func talkingMovesMouth() {
        let a = Animator(seed: 2)
        let goal = FaceParams.target(.talking, "neutral")
        let opens = runFrames(a, goal, 2.0, talking: true).dropFirst(30).map(\.p.mouthOpen)
        #expect(opens.max()! - opens.min()! > 0.3)
        let closed = runFrames(a, goal, 1.0, talking: false, t0: 2.0).map(\.p.mouthOpen)
        #expect(closed.last! < 0.05)
    }

    @Test func idleWandersGaze() {
        let xs = runFrames(Animator(seed: 4), FaceParams.target(.idle, "neutral"), 10.0).map(\.p.gazeX)
        #expect(xs.max()! - xs.min()! > 0.1)
    }

    @Test func deterministicWithSeed() {
        let g = FaceParams.target(.idle, "happy")
        #expect(runFrames(Animator(seed: 9), g, 5.0).map(\.p) == runFrames(Animator(seed: 9), g, 5.0).map(\.p))
    }

    @Test func stableForLargeDt() {
        let a = Animator(seed: 5)
        var t = 0.0
        for i in 0..<50 {
            t += 5.0
            let tgt = FaceParams.target(Activity.allCases[i % Activity.allCases.count], emotions[i % 9])
            let p = a.step(tgt, dt: 5.0, talking: i % 2 == 0, now: t)
            #expect(numbers.allSatisfy { p[keyPath: $0].isFinite })
            #expect(abs(p.gazeX) < 3 && (0..<3).contains(p.eyeH))
        }
    }

    /// No half-happy, half-sad eyes: lid and eye shapes change only while the eyes are shut.
    @Test func expressionChangesHappenBehindABlink() {
        let a = Animator(seed: 8)
        let happy = FaceParams.target(.talking, "happy"), sad = FaceParams.target(.idle, "sad")
        _ = runFrames(a, happy, 1.0)
        let frames = runFrames(a, sad, 1.0, t0: 1.0)
        for (_, p) in frames where p.eyeH > 0.4 * sad.eyeH {  // visible: the old shape or the new one, never a mix
            for k in Animator.shape {
                let v = p[keyPath: k]
                #expect(min(abs(v - happy[keyPath: k]), abs(v - sad[keyPath: k])) < 1e-6)
            }
        }
        let p = frames.last!.p
        #expect(Animator.shape.allSatisfy { approx(p[keyPath: $0], sad[keyPath: $0]) })
        #expect(frames[0].t - 1.0 < 0.05 && frames.prefix(20).map(\.p.eyeH).min()! < 0.4 * sad.eyeH)
    }

    /// At the frame rate its activity runs at (the widget's), every blink still shows >= 2 visibly shut frames.
    @Test(arguments: Activity.allCases.filter { $0 != .asleep })
    func blinksSurviveTheFrameRate(activity: Activity) {
        let rates: [Activity: Double] = [.idle: 40, .sleepy: 66, .asleep: 100]
        let dt = (rates[activity] ?? 33) / 1000
        let goal = FaceParams.target(activity, "neutral")
        let a = Animator(seed: 11)
        var shut: [Double: [Double]] = [:]  // blink start -> eye heights of the frames that show it
        for i in 1..<Int(40 / dt) {
            let p = a.step(goal, dt: dt, talking: false, now: Double(i) * dt)
            if p.eyeH < 0.9 * goal.eyeH { shut[a.blinkAt, default: []].append(p.eyeH) }  // outside a blink eyeH sits at the goal
        }
        let complete = shut.filter { $0.key < 39 }.map(\.value)
        #expect(complete.count >= 5)
        #expect(complete.allSatisfy { $0.count >= 2 && $0.min()! < 0.5 * goal.eyeH })
    }

    /// Python's callers never pass a negative dt, and exp(-14 * dt) overflows for dt < -50: the face
    /// must not turn to NaN. A negative dt counts as no time at all.
    @Test(arguments: [-0.001, -1.0, -100.0], [false, true])
    func aNegativeDtCountsAsNoTime(dt: Double, talking: Bool) {
        let first = FaceParams.target(.idle, "neutral"), goal = FaceParams.target(.talking, "happy")
        let a = Animator(seed: 1), b = Animator(seed: 1)
        _ = a.step(first, dt: 1.0 / 60, talking: false, now: 0)
        _ = b.step(first, dt: 1.0 / 60, talking: false, now: 0)
        let got = a.step(goal, dt: dt, talking: talking, now: 1)
        #expect(numbers.allSatisfy { got[keyPath: $0].isFinite })
        #expect(got == b.step(goal, dt: 0, talking: talking, now: 1))
    }

    // MARK: golden parity with Python

    @Test func pythonRandomMatches() {
        let golden: [(UInt64, [Double], Double)] = [  // (seed, first three random(), uniform(2, 6) after them)
            (0, [0.8444218515250481, 0.7579544029403025, 0.420571580830845], 3.0356670011718534),
            (1, [0.13436424411240122, 0.8474337369372327, 0.763774618976614], 3.020276102957687),
            (12345, [0.41661987254534116, 0.010169169457068361, 0.8252065092537432], 3.194559420798371),
            (1099511627781, [0.5043802970418443, 0.2686044399723282, 0.9257865475671585], 4.123836957169808),  // 2**40 + 5: two key words
        ]
        for (seed, firsts, u) in golden {
            var r = PyRandom(seed: seed)
            #expect(firsts.map { _ in r.random() } == firsts)
            #expect(r.uniform(2, 6) == u)
        }
        var r = PyRandom(seed: 1)
        #expect((0..<3).map { _ in r.next32() } == [577090037, 2444712010, 3639700191])  // getrandbits(32)
    }

    @Test func targetTableMatchesPython() {
        #expect(goldenTargets.count == Activity.allCases.count * emotions.count)
        for (activity, emotion, fx, values) in goldenTargets {
            let p = FaceParams.target(activity, emotion)
            for (k, v) in zip(FaceParams.floats, values) {
                #expect(abs(p[keyPath: k] - v) <= 1e-9, "\(activity)/\(emotion) \(k)")
            }
            #expect(p.effects.sorted().joined(separator: " ") == fx, "\(activity)/\(emotion) effects")
            #expect(p.bob == 0)
        }
    }

    @Test func idleTraceMatchesPython() {
        let idle = FaceParams.target(.idle, "neutral")
        expectTrace("idle", Animator(seed: 1), goldenFrames(600, dt: 1.0 / 60) { _ in idle }, [
            (1, [1, 1, 0.55, 0.004308848364635, -0.002286303429335, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 0.02617694830787], ""),
            (2, [1, 1, 0.55, 0.01482111049714, -0.00786417921649, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 0.05233595624294], ""),
            (30, [1, 1, 0.55, 0.1832952579027, -0.09725767566188, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 0.7071067811865], ""),
            (100, [1, 1, 0.55, 0.1846422329533, -0.09797238952894, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 0.5], ""),
            (300, [1, 1, 0.55, 0.1061150848895, 0.1154893296256, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 1], ""),
            (400, [1, 0.6853414681404, 0.55, -0.3294083819938, 0.1342737632387, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, -0.8660254037844], ""),
            (600, [1, 1, 0.55, -0.3485257626542, -0.02184512237807, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1, 6.123233995737e-16], ""),
        ], sums: [600, 589.564841451903, 330.000000000004, -22.7679088861193, 4.76868913824458, 0, 0, 0, 0, 0, 90.0000000000006, 0, 600, 112800, 510.000000000006, 480.000000000005, 600, 76.390009311136])
    }

    /// Talking (mouth chatter draws from the generator) for a second, then a different expression.
    @Test func expressionSwapTraceMatchesPython() {
        let happy = FaceParams.target(.talking, "happy"), sad = FaceParams.target(.idle, "sad")
        let dt = 1.0 / 60
        let frames = goldenFrames(60, dt: dt, target: { _ in happy }, talking: { _ in true })
            + (1...60).map { GoldenFrame(target: sad, dt: dt, now: Double(60 + $0) * dt) }
        expectTrace("swap", Animator(seed: 8), frames, [
            (1, [1, 1.1, 0.55, -0.001831203664526, 0.0005735578783707, 0, 0, 0.55, 0, 0, 1, 0.4374426461038, 1.25, 168, 0.85, 0.8, 0.3, 0.02617694830787], "blush"),
            (30, [1, 1.1, 0.55, -0.07789806453078, 0.02439873264071, 0, 0, 0.55, 0, 0, 1, 0.1806971871282, 1.25, 168, 0.85, 0.8, 0.3, 0.7071067811865], "blush"),
            (60, [1, 1.1, 0.55, -0.07846953252606, 0.02457772418452, 0, 0, 0.55, 0, 0, 1, 0.4613985079099, 1.25, 168, 0.85, 0.8, 0.3, 1], "blush"),
            (62, [1, 0.7439734714391, 0.55, -0.0931670230636, 0.06128891463636, 0, 0, 0.55, 0, 0, 1, 0.424362353465, 1.21387879628, 171.8529283968, 0.84598653292, 0.7839461316801, 0.3561885391197, 0.9986295347546], ""),
            (65, [1, 0.09787195062756, 0.55, -0.1380306375715, 0.1733502778099, 0, 0, 0.55, 0, 0, 1, 0.3113087962238, 1.103618143317, 183.6140647129, 0.8337353492574, 0.7349413970297, 0.5277051103962, 0.9914448613738], ""),
            (68, [1, 0.4085509523387, 0.55, -0.1804015863421, 0.2791856856016, 0.22, -0.6, 0, 0, 0, -0.7, 0.2045362783159, 0.9994833612685, 194.721774798, 0.8221648179187, 0.6886592716749, 0.6896925491378, 0.9781476007338], ""),
            (70, [1, 0.9781831807186, 0.55, -0.2023837287246, 0.3340933775854, 0.22, -0.6, 0, 0, 0, -0.7, 0.1491424042724, 0.9454579517966, 200.4844851417, 0.8161619946441, 0.6646479785763, 0.7737320749831, 0.9659258262891], ""),
            (90, [1, 0.9213131100304, 0.55, -0.2602326605461, 0.4785903842065, 0.22, -0.6, 0, 0, 0, -0.7, 0.003365927826375, 0.803282775076, 215.6498373252, 0.8003647527862, 0.6014590111449, 0.9948934609929, 0.7071067811865], ""),
            (120, [1, 0.9200022451275, 0.55, -0.2615660871759, 0.481921064669, 0.22, -0.6, 0, 0, 0, -0.7, 5.754991654179e-06, 0.8000056128189, 215.9994012993, 0.8000006236465, 0.6000024945862, 0.9999912689484, 1.224646799147e-16], ""),
        ], sums: [120, 117.252707569684, 65.9999999999999, -18.2911026442941, 26.5004568663151, 12.1, -33, 35.75, 0, 0, 26.4999999999999, 24.3328641118277, 126.632135741713, 22652.5721875506, 99.4035706379681, 85.6142825518723, 72.3500110684468, 76.390009311136])
    }

    @Test func asleepTraceMatchesPython() {
        let asleep = FaceParams.target(.asleep, "neutral")
        expectTrace("asleep", Animator(seed: 3), goldenFrames(400, dt: 1.0 / 60) { _ in asleep }, [
            (1, [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0, 0.01745240643728], "zzz"),
            (120, [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0, 0.8660254037844], "zzz"),
            (400, [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0, 0.6427876096865], "zzz"),
        ], sums: [400, 40.0000000000003, 400, 0, 179.999999999999, 0, 0, 0, 0, 0, 0, 0, 179.999999999999, 75200, 220.000000000001, 139.999999999999, 0, 13.7257195314669])
    }

    /// Five-second frames cycling through the activities and emotions: the spring must stay exact.
    @Test func largeDtTraceMatchesPython() {
        let frames = (0..<50).map { i in
            GoldenFrame(target: FaceParams.target(Activity.allCases[i % 9], emotions[i % 9]), dt: 5.0,
                        talking: i % 2 == 0, now: Double(i + 1) * 5.0)  // exact in binary: equals Python's running t += 5.0
        }
        expectTrace("bigdt", Animator(seed: 5), frames, [
            (1, [1, 1, 0.55, 0.206635495896, 0.1769801135108, 0, 0, 0, 0, 0, 0.15, 0.559280096966, 1, 188, 0.85, 0.8, 1, 1], ""),
            (2, [1.05, 1.17, 0.55, 0.1241398807595, -0.07616407149809, 0, 0, 0, 0, 0, 0.15, 1.578606838786e-29, 0.95, 168, 0.85, 0.8, 0.4, 6.123233995737e-16], "blush pulse"),
            (10, [1, 1, 0.55, -0.1390486294614, 0.04124399896306, 0, 0, 0, 0, 0, 0.15, 1.160257280567e-29, 1, 188, 0.85, 0.8, 1, -4.910966809321e-16], ""),
            (50, [1, 1.05, 0.55, 0.02014690488858, 0.107663096616, 0, 0, 0, 0, 0, 0.15, 7.216363500515e-30, 0.85, 34, 0.8, 0.8, 0.3, 4.017708074095e-14], "sweat"),
        ], sums: [49.38, 45.29, 27.5, 2.17547178010411, -0.388148565573832, 0, 0, 0, 0, 0, 7.50000000000001, 9.39517672220346, 33.3, 8472, 38.3, 35.25, 10.2, -2.45548340466059e-15])
    }

    /// Every (activity, emotion) target for 1.5 s each, with talking and a look switching on and off.
    @Test func everyTargetTraceMatchesPython() {
        let combos = Activity.allCases.flatMap { a in emotions.map { FaceParams.target(a, $0) } }
        let frames = goldenFrames(3645, dt: 1.0 / 30, target: { combos[($0 - 1) / 45] }, talking: { ($0 / 20) % 2 == 0 },
                                  look: { ($0 / 90) % 3 == 1 ? Vec(0.5, -0.5) : nil })
        expectTrace("every", Animator(seed: 21), frames, [
            (1, [1, 1, 0.55, 0.007585449432583, -0.0006710365390756, 0, 0, 0, 0, 0, 0.15, 0.6458639739608, 1, 188, 0.85, 0.8, 1, 0.05233595624294], ""),
            (46, [1, 1.00401346708, 0.55, 0.09449995727378, -0.008359811087714, 0, 0, 0, 0, 0, 0.15, 0.192775460205, 1.01204040124, 186.394613168, 0.85, 0.8, 1, 0.6691306063589], "blush"),
            (1000, [0.85, 0.8500000000228, 0.55, 0.6000000000665, -0.6213147417549, 0.12, -0.55, 0, 0.15, 0, -0.5, 0.5020393672243, 0.3739790843922, 34.53286857197, 0.7946713145827, 0.8, 1.043394728577e-46, 0.8660254037844], "dots sweat"),
            (3645, [1, 0.1, 1, -3.315766351649e-99, 0.45, 0, 0, 0, 0, 0, 0, 0.5626528447387, 0.45, 188, 0.55, 0.35, 0, 1], "zzz"),
        ], sums: [3596.39999999998, 3018.63203398455, 2185.6499999999, 224.865150410217, -101.034885759009, 682.138299232736, -479.860000000008, 477.551700767264, 23.2499999999993, 360, 485.499999999992, 815.511218599898, 2315.08229652744, 699120.000000001, 2613.38579810599, 2469.95369715879, 633.785993686353, 29.1449808153795])
    }
}

// target(activity, emotion): activity, emotion, effects, then eyeW ... wander (FaceParams.floats order)
private let goldenTargets: [(Activity, String, String, [Double])] = [
    (.idle, "neutral", "", [1, 1, 0.55, 0, 0, 0, 0, 0, 0, 0, 0.15, 0, 1, 188, 0.85, 0.8, 1]),
    (.idle, "happy", "blush", [1, 1.05, 0.55, 0, 0, 0, 0, 0.55, 0, 0, 1, 0, 1.15, 168, 0.85, 0.8, 1]),
    (.idle, "curious", "", [1, 1.12, 0.55, 0.35, -0.15, 0, 0, 0, 0.4, 0, 0.1, 0.2, 0.5, 188, 0.85, 0.8, 1]),
    (.idle, "proud", "sparkle", [1, 1, 0.55, 0, -0.35, 0.18, 0, 0.42, 0, 0, 0.9, 0, 1.2, 44, 0.7, 0.8, 1]),
    (.idle, "concerned", "sweat", [1, 1, 0.55, 0, 0.1, 0.12, -0.55, 0, 0, 0, -0.25, 0, 0.75, 34, 0.8, 0.8, 1]),
    (.idle, "confused", "question", [1, 1, 0.55, -0.35, -0.1, 0, 0.25, 0, -0.5, 0, -0.15, 0, 0.7, 188, 0.85, 0.8, 1]),
    (.idle, "playful", "blush", [1, 1, 0.55, -0.3, 0, 0, 0, 0.45, 0, 1, 0.9, 0.35, 1, 318, 0.45, 0.8, 1]),
    (.idle, "sad", "", [1, 0.92, 0.55, 0, 0.4, 0.22, -0.6, 0, 0, 0, -0.7, 0, 0.8, 216, 0.8, 0.6, 1]),
    (.idle, "calm", "", [1, 1, 0.55, 0, 0, 0.4, 0, 0, 0, 0, 0.5, 0, 0.75, 176, 0.6, 0.6, 0.4]),
    (.listening, "neutral", "pulse", [1.05, 1.12, 0.55, 0, -0.1, 0, 0, 0, 0, 0, 0.15, 0, 0.8, 188, 0.85, 0.8, 0.4]),
    (.listening, "happy", "blush pulse", [1.05, 1.17, 0.55, 0, -0.1, 0, 0, 0.55, 0, 0, 1, 0, 0.95, 168, 0.85, 0.8, 0.4]),
    (.listening, "curious", "pulse", [1.05, 1.24, 0.55, 0.35, -0.25, 0, 0, 0, 0.4, 0, 0.1, 0.2, 0.3, 188, 0.85, 0.8, 0.4]),
    (.listening, "proud", "pulse sparkle", [1.05, 1.12, 0.55, 0, -0.45, 0.18, 0, 0.42, 0, 0, 0.9, 0, 1, 44, 0.7, 0.8, 0.4]),
    (.listening, "concerned", "pulse sweat", [1.05, 1.12, 0.55, 0, 0, 0.12, -0.55, 0, 0, 0, -0.25, 0, 0.55, 34, 0.8, 0.8, 0.4]),
    (.listening, "confused", "pulse question", [1.05, 1.12, 0.55, -0.35, -0.2, 0, 0.25, 0, -0.5, 0, -0.15, 0, 0.5, 188, 0.85, 0.8, 0.4]),
    (.listening, "playful", "blush pulse", [1.05, 1.12, 0.55, -0.3, -0.1, 0, 0, 0.45, 0, 1, 0.9, 0.35, 0.8, 318, 0.45, 0.8, 0.4]),
    (.listening, "sad", "pulse", [1.05, 1.04, 0.55, 0, 0.3, 0.22, -0.6, 0, 0, 0, -0.7, 0, 0.6, 216, 0.8, 0.6, 0.4]),
    (.listening, "calm", "pulse", [1.05, 1.12, 0.55, 0, -0.1, 0.4, 0, 0, 0, 0, 0.5, 0, 0.55, 176, 0.6, 0.6, 0]),
    (.thinking, "neutral", "dots", [0.85, 0.85, 0.55, 0.6, -0.7, 0, 0, 0, 0.15, 0, -0.1, 0, 0.6, 188, 0.85, 0.8, 0]),
    (.thinking, "happy", "blush dots", [0.85, 0.9, 0.55, 0.6, -0.7, 0, 0, 0.55, 0.15, 0, 0.75, 0, 0.75, 168, 0.85, 0.8, 0]),
    (.thinking, "curious", "dots", [0.85, 0.97, 0.55, 0.95, -0.85, 0, 0, 0, 0.55, 0, -0.15, 0.2, 0.2, 188, 0.85, 0.8, 0]),
    (.thinking, "proud", "dots sparkle", [0.85, 0.85, 0.55, 0.6, -1, 0.18, 0, 0.42, 0.15, 0, 0.65, 0, 0.8, 44, 0.7, 0.8, 0]),
    (.thinking, "concerned", "dots sweat", [0.85, 0.85, 0.55, 0.6, -0.6, 0.12, -0.55, 0, 0.15, 0, -0.5, 0, 0.35, 34, 0.8, 0.8, 0]),
    (.thinking, "confused", "dots question", [0.85, 0.85, 0.55, 0.25, -0.8, 0, 0.25, 0, -0.35, 0, -0.4, 0, 0.3, 188, 0.85, 0.8, 0]),
    (.thinking, "playful", "blush dots", [0.85, 0.85, 0.55, 0.3, -0.7, 0, 0, 0.45, 0.15, 1, 0.65, 0.35, 0.6, 318, 0.45, 0.8, 0]),
    (.thinking, "sad", "dots", [0.85, 0.77, 0.55, 0.6, -0.3, 0.22, -0.6, 0, 0.15, 0, -0.95, 0, 0.4, 216, 0.8, 0.6, 0]),
    (.thinking, "calm", "dots", [0.85, 0.85, 0.55, 0.6, -0.7, 0.4, 0, 0, 0.15, 0, 0.25, 0, 0.35, 176, 0.6, 0.6, 0]),
    (.working, "neutral", "gear", [1.08, 0.9, 0.55, 0, 0.35, 0.3, 0.08, 0, 0, 0, 0, 0, 0.6, 188, 0.85, 0.8, 0]),
    (.working, "happy", "blush gear", [1.08, 0.95, 0.55, 0, 0.35, 0.2470588235294, 0.08, 0.4529411764706, 0, 0, 0.85, 0, 0.75, 168, 0.85, 0.8, 0]),
    (.working, "curious", "gear", [1.08, 1.02, 0.55, 0.35, 0.2, 0.3, 0.08, 0, 0.4, 0, -0.05, 0.2, 0.2, 188, 0.85, 0.8, 0]),
    (.working, "proud", "gear sparkle", [1.08, 0.9, 0.55, 0, 0, 0.3733333333333, 0.08, 0.3266666666667, 0, 0, 0.75, 0, 0.8, 44, 0.7, 0.8, 0]),
    (.working, "concerned", "gear sweat", [1.08, 0.9, 0.55, 0, 0.45, 0.42, -0.47, 0, 0, 0, -0.4, 0, 0.35, 34, 0.8, 0.8, 0]),
    (.working, "confused", "gear question", [1.08, 0.9, 0.55, -0.35, 0.25, 0.3, 0.33, 0, -0.5, 0, -0.3, 0, 0.3, 188, 0.85, 0.8, 0]),
    (.working, "playful", "blush gear", [1.08, 0.9, 0.55, -0.3, 0.35, 0.28, 0.08, 0.42, 0, 1, 0.75, 0.35, 0.6, 318, 0.45, 0.8, 0]),
    (.working, "sad", "gear", [1.08, 0.82, 0.55, 0, 0.75, 0.52, -0.52, 0, 0, 0, -0.85, 0, 0.4, 216, 0.8, 0.6, 0]),
    (.working, "calm", "gear", [1.08, 0.9, 0.55, 0, 0.35, 0.7, 0.08, 0, 0, 0, 0.35, 0, 0.35, 176, 0.6, 0.6, 0]),
    (.talking, "neutral", "", [1, 1.05, 0.55, 0, 0, 0, 0, 0, 0, 0, 0.15, 0, 1.1, 188, 0.85, 0.8, 0.3]),
    (.talking, "happy", "blush", [1, 1.1, 0.55, 0, 0, 0, 0, 0.55, 0, 0, 1, 0, 1.25, 168, 0.85, 0.8, 0.3]),
    (.talking, "curious", "", [1, 1.17, 0.55, 0.35, -0.15, 0, 0, 0, 0.4, 0, 0.1, 0.2, 0.6, 188, 0.85, 0.8, 0.3]),
    (.talking, "proud", "sparkle", [1, 1.05, 0.55, 0, -0.35, 0.18, 0, 0.42, 0, 0, 0.9, 0, 1.3, 44, 0.7, 0.8, 0.3]),
    (.talking, "concerned", "sweat", [1, 1.05, 0.55, 0, 0.1, 0.12, -0.55, 0, 0, 0, -0.25, 0, 0.85, 34, 0.8, 0.8, 0.3]),
    (.talking, "confused", "question", [1, 1.05, 0.55, -0.35, -0.1, 0, 0.25, 0, -0.5, 0, -0.15, 0, 0.8, 188, 0.85, 0.8, 0.3]),
    (.talking, "playful", "blush", [1, 1.05, 0.55, -0.3, 0, 0, 0, 0.45, 0, 1, 0.9, 0.35, 1.1, 318, 0.45, 0.8, 0.3]),
    (.talking, "sad", "", [1, 0.97, 0.55, 0, 0.4, 0.22, -0.6, 0, 0, 0, -0.7, 0, 0.9, 216, 0.8, 0.6, 0.3]),
    (.talking, "calm", "", [1, 1.05, 0.55, 0, 0, 0.4, 0, 0, 0, 0, 0.5, 0, 0.85, 176, 0.6, 0.6, 0]),
    (.waiting, "neutral", "", [1, 1.18, 0.55, 0, -0.2, 0, -0.12, 0, 0, 0, 0.25, 0, 0.75, 188, 0.85, 0.8, 0]),
    (.waiting, "happy", "blush", [1, 1.23, 0.55, 0, -0.2, 0, -0.12, 0.55, 0, 0, 1, 0, 0.9, 168, 0.85, 0.8, 0]),
    (.waiting, "curious", "", [1, 1.3, 0.55, 0.35, -0.35, 0, -0.12, 0, 0.4, 0, 0.2, 0.2, 0.25, 188, 0.85, 0.8, 0]),
    (.waiting, "proud", "sparkle", [1, 1.18, 0.55, 0, -0.55, 0.18, -0.12, 0.42, 0, 0, 1, 0, 0.95, 44, 0.7, 0.8, 0]),
    (.waiting, "concerned", "sweat", [1, 1.18, 0.55, 0, -0.1, 0.12, -0.67, 0, 0, 0, -0.15, 0, 0.5, 34, 0.8, 0.8, 0]),
    (.waiting, "confused", "question", [1, 1.18, 0.55, -0.35, -0.3, 0, 0.13, 0, -0.5, 0, -0.05, 0, 0.45, 188, 0.85, 0.8, 0]),
    (.waiting, "playful", "blush", [1, 1.18, 0.55, -0.3, -0.2, 0, -0.12, 0.45, 0, 1, 1, 0.35, 0.75, 318, 0.45, 0.8, 0]),
    (.waiting, "sad", "", [1, 1.1, 0.55, 0, 0.2, 0.22, -0.72, 0, 0, 0, -0.6, 0, 0.55, 216, 0.8, 0.6, 0]),
    (.waiting, "calm", "", [1, 1.18, 0.55, 0, -0.2, 0.4, -0.12, 0, 0, 0, 0.6, 0, 0.5, 176, 0.6, 0.6, 0]),
    (.error, "neutral", "sweat", [0.9, 0.75, 0.55, 0, 0, 0.15, -0.35, 0, 0, 0, -0.45, 0, 0.8, 356, 0.75, 0.8, 0]),
    (.error, "happy", "blush sweat", [0.9, 0.8, 0.55, 0, 0, 0.15, -0.35, 0.55, 0, 0, 0.4, 0, 0.95, 356, 0.75, 0.8, 0]),
    (.error, "curious", "sweat", [0.9, 0.87, 0.55, 0.35, -0.15, 0.15, -0.35, 0, 0.4, 0, -0.5, 0.2, 0.3, 356, 0.75, 0.8, 0]),
    (.error, "proud", "sparkle sweat", [0.9, 0.75, 0.55, 0, -0.35, 0.308, -0.35, 0.392, 0, 0, 0.3, 0, 1, 356, 0.75, 0.8, 0]),
    (.error, "concerned", "sweat", [0.9, 0.75, 0.55, 0, 0.1, 0.27, -0.9, 0, 0, 0, -0.85, 0, 0.55, 356, 0.75, 0.8, 0]),
    (.error, "confused", "question sweat", [0.9, 0.75, 0.55, -0.35, -0.1, 0.15, -0.1, 0, -0.5, 0, -0.75, 0, 0.5, 356, 0.75, 0.8, 0]),
    (.error, "playful", "blush sweat", [0.9, 0.75, 0.55, -0.3, 0, 0.15, -0.35, 0.45, 0, 1, 0.3, 0.35, 0.8, 356, 0.75, 0.8, 0]),
    (.error, "sad", "sweat", [0.9, 0.67, 0.55, 0, 0.4, 0.37, -0.95, 0, 0, 0, -1, 0, 0.6, 356, 0.75, 0.6, 0]),
    (.error, "calm", "sweat", [0.9, 0.75, 0.55, 0, 0, 0.55, -0.35, 0, 0, 0, -0.1, 0, 0.55, 356, 0.75, 0.6, 0]),
    (.sleepy, "neutral", "", [1, 1, 0.55, 0, 0.3, 0.55, 0, 0, 0, 0, 0.05, 0, 0.6, 188, 0.65, 0.5, 0]),
    (.sleepy, "happy", "blush", [1, 1.05, 0.55, 0, 0.3, 0.35, 0, 0.35, 0, 0, 0.9, 0, 0.75, 168, 0.65, 0.5, 0]),
    (.sleepy, "curious", "", [1, 1.12, 0.55, 0.35, 0.15, 0.55, 0, 0, 0.4, 0, 0, 0.2, 0.2, 188, 0.65, 0.5, 0]),
    (.sleepy, "proud", "sparkle", [1, 1, 0.55, 0, -0.05, 0.444347826087, 0, 0.255652173913, 0, 0, 0.8, 0, 0.8, 44, 0.65, 0.5, 0]),
    (.sleepy, "concerned", "sweat", [1, 1, 0.55, 0, 0.4, 0.67, -0.55, 0, 0, 0, -0.35, 0, 0.35, 34, 0.65, 0.5, 0]),
    (.sleepy, "confused", "question", [1, 1, 0.55, -0.35, 0.2, 0.55, 0.25, 0, -0.5, 0, -0.25, 0, 0.3, 188, 0.65, 0.5, 0]),
    (.sleepy, "playful", "blush", [1, 1, 0.55, -0.3, 0.3, 0.385, 0, 0.315, 0, 1, 0.8, 0.35, 0.6, 318, 0.65, 0.5, 0]),
    (.sleepy, "sad", "", [1, 0.92, 0.55, 0, 0.7, 0.7, -0.6, 0, 0, 0, -0.8, 0, 0.4, 216, 0.65, 0.3, 0]),
    (.sleepy, "calm", "", [1, 1, 0.55, 0, 0.3, 0.7, 0, 0, 0, 0, 0.4, 0, 0.35, 176, 0.65, 0.3, 0]),
    (.asleep, "neutral", "zzz", [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0]),
    (.asleep, "happy", "zzz", [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0]),
    (.asleep, "curious", "zzz", [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0]),
    (.asleep, "proud", "zzz", [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0]),
    (.asleep, "concerned", "zzz", [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0]),
    (.asleep, "confused", "zzz", [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0]),
    (.asleep, "playful", "zzz", [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0]),
    (.asleep, "sad", "zzz", [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0]),
    (.asleep, "calm", "zzz", [1, 0.1, 1, 0, 0.45, 0, 0, 0, 0, 0, 0, 0, 0.45, 188, 0.55, 0.35, 0]),
]
