// Pure time-stepped face animation: springs, blinks, glances, breathing, talking.
// Port of src/robo/face/animator.py.
import Foundation

/// Python's `random.Random` (Mersenne Twister, `init_by_array` seeding), so a seed gives the same
/// blinks and glances as the Python animator; that is what lets the tests compare traces.
struct PyRandom {
    private var mt = [UInt32](repeating: 0, count: 624)
    private var index = 624

    init(seed: UInt64) {
        mt[0] = 19650218
        for i in 1..<624 { mt[i] = 1812433253 &* (mt[i - 1] ^ (mt[i - 1] >> 30)) &+ UInt32(i) }
        let key = seed >> 32 == 0 ? [UInt32(seed)] : [UInt32(truncatingIfNeeded: seed), UInt32(seed >> 32)]
        var i = 1, j = 0
        for _ in 0..<max(624, key.count) {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1664525)) &+ key[j] &+ UInt32(j)
            i += 1; j += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
            if j >= key.count { j = 0 }
        }
        for _ in 0..<623 {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1566083941)) &- UInt32(i)
            i += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
        }
        mt[0] = 0x8000_0000
    }

    mutating func next32() -> UInt32 {
        if index >= 624 {
            for k in 0..<624 {
                let y = (mt[k] & 0x8000_0000) | (mt[(k + 1) % 624] & 0x7FFF_FFFF)
                mt[k] = mt[(k + 397) % 624] ^ (y >> 1) ^ (y & 1 == 0 ? 0 : 0x9908_B0DF)
            }
            index = 0
        }
        var y = mt[index]
        index += 1
        y ^= y >> 11
        y ^= (y << 7) & 0x9D2C_5680
        y ^= (y << 15) & 0xEFC6_0000
        y ^= y >> 18
        return y
    }

    mutating func random() -> Double {
        let a = Double(next32() >> 5), b = Double(next32() >> 6)
        return (a * 67108864.0 + b) / 9007199254740992.0
    }

    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * random() }
}

public enum Look {
    public static let range = 500.0  // px of cursor distance at which the eyes turn as far as they go
    public static let gain = 0.9  // how far that is (1 = the eye reaches its limit)
    public static let stale = 15.0  // s without cursor movement before robo stops staring at it
    public static let walk = 0.6  // how far the eyes lead while it walks
}

/// Where the eyes point (x, y in -1..1): at the cursor while it moves, else along the walk,
/// else nil (free glances). A far cursor pulls harder than a near one.
public func lookAt(centre: Vec, cursor: Vec, stillFor: Double, heading: Int = 0) -> Vec? {
    if stillFor < Look.stale {
        let dx = cursor.x - centre.x, dy = cursor.y - centre.y
        let d = hypot(dx, dy)
        if d < 1 { return Vec(0, 0) }
        let k = Look.gain * min(1.0, d / Look.range) / d
        return Vec(dx * k, dy * k)
    }
    return heading != 0 ? Vec(Look.walk * Double(heading), 0) : nil
}

/// Eases the face toward a target and layers life on top. Deterministic with a seed.
public final class Animator {
    static let omega = 14.0  // spring stiffness (rad/s); critically damped
    static let blink = 0.15  // seconds, close + open
    // Eye/mouth shape: changing these half-way looks broken (half happy, half sad), so a new
    // expression swaps them in one step at the middle of a blink, like EMO-style robots do.
    static let shape: [FaceKey] = [\.eyeRound, \.lidTop, \.lidAngle, \.lidBottom, \.skew, \.wink, \.mouthCurve]
    private static let sprung = FaceParams.floats.filter { !shape.contains($0) }

    var rng: PyRandom
    /// The eased values and their velocities (nil until the first step); the app may set `x` to snap.
    public var x: [FaceKey: Double]?
    public var v = Dictionary(uniqueKeysWithValues: FaceParams.floats.map { ($0, 0.0) })
    var nextBlink: Double
    public private(set) var blinkAt = -1.0
    var nextGlance = 0.0
    var glance = Vec(0, 0)
    var phase = 0.0
    var shape: [FaceKey: Double]?  // the expression shape the eyes show now

    /// A seed makes the blinks and glances repeat, and match Python's `Animator(seed)`.
    public init(seed: UInt64? = nil) {
        rng = PyRandom(seed: seed ?? .random(in: .min ... .max))
        nextBlink = rng.uniform(2, 6)
    }

    /// `look` (see `lookAt`) replaces the free glances; poses that keep their own gaze
    /// (wander 0: thinking, working, asleep) ignore it.
    public func step(_ target: FaceParams, dt: Double, talking: Bool, now: Double, look: Vec? = nil) -> FaceParams {
        let dt = max(dt, 0)  // Python's callers never pass dt < 0; exp(-14 dt) would overflow to NaN, so it counts as no time
        var x = self.x ?? Dictionary(uniqueKeysWithValues: FaceParams.floats.map { ($0, target[keyPath: $0]) })
        let asleep = target.effects.contains("zzz")
        var goal = Dictionary(uniqueKeysWithValues: FaceParams.floats.map { ($0, target[keyPath: $0]) })
        let newShape = Dictionary(uniqueKeysWithValues: Animator.shape.map { ($0, goal[$0]!) })
        var shape = self.shape ?? newShape
        var p = (now - blinkAt) / Animator.blink
        if newShape != shape {
            if !(0...1 ~= p) {  // a new expression: blink, and swap the shape mid-blink
                blinkAt = now
                p = 0
            }
            if p >= 0.5 { shape = newShape }
        }
        for k in Animator.shape {  // shape is never sprung: it switches while the eyes are shut
            x[k] = shape[k]!
            v[k] = 0
        }
        self.shape = shape

        if now >= nextGlance {  // micro-glance: pick a new small gaze offset
            nextGlance = now + rng.uniform(1.2, 4.0)
            let gx = rng.uniform(-0.35, 0.35)
            let gy = rng.uniform(-0.2, 0.2)
            glance = Vec(gx, gy)
        }
        let g = look ?? glance
        goal[\.gazeX]! += g.x * target.wander
        goal[\.gazeY]! += g.y * target.wander

        for k in Animator.sprung {  // exact critically damped spring
            let e = x[k]! - goal[k]!, vel = v[k]!
            let decay = exp(-Animator.omega * dt)
            let c = vel + Animator.omega * e
            x[k] = goal[k]! + (e + c * dt) * decay
            v[k] = (vel - Animator.omega * c * dt) * decay
        }

        if talking {  // mouth chatter ~6-9 Hz with jitter
            phase += dt * 2 * Double.pi * rng.uniform(6, 9)
            let o = 0.5 + 0.5 * sin(phase)
            x[\.mouthOpen] = min(1.0, 0.1 + 0.6 * o * rng.uniform(0.6, 1.0))
            v[\.mouthOpen] = 0
        }

        if now >= nextBlink {
            nextBlink = now + rng.uniform(2, 6)
            if !asleep && !(0...1 ~= p) { blinkAt = now }
        }
        p = (now - blinkAt) / Animator.blink
        let squash = 0...1 ~= p ? 1 - 0.92 * sin(Double.pi * p) : 1.0

        var out = target
        for k in FaceParams.floats { out[keyPath: k] = x[k]! }
        self.x = x
        let breath = sin(now * 2 * Double.pi / (asleep ? 6.0 : 4.0))
        out.eyeH *= squash
        out.bob = breath
        return out
    }
}
