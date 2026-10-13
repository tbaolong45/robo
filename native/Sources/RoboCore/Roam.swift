// Where the floating face goes: a pure, time-stepped wander along the screen edges.
// Port of src/robo/roam.py (multi-screen version): no AppKit, time comes in as an argument.
import Foundation

public typealias Vec = SIMD2<Double>
public typealias IVec = SIMD2<Int>

public struct Rect: Equatable {
    public var x, y, w, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public enum Roam {
    public static let speed = 40.0  // px/s average travel speed (ease-in-out peaks at 1.5x)
    public static let rest = 20.0...60.0  // s to rest between drifts
    public static let margin = 160.0  // px: drift targets lie this close to the bottom, left or right edge
    public static let edge = 24.0  // px gap from the bottom-right corner where it sleeps
    public static let hold = 600.0  // s to stay where the user dropped it
    public static let maxDT = 0.25  // s: a longer gap (a suspended laptop) counts as one capped frame
}

/// A small seedable generator: `Roamer(seed:)` replays the same path, like Python's `random.Random`.
public struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `a...b` for either order (Swift's `random(in:)` traps when a > b, Python's `uniform` does not).
func uniform<G: RandomNumberGenerator>(_ a: Double, _ b: Double, _ rng: inout G) -> Double {
    a + (b - a) * Double.random(in: 0..<1, using: &rng)
}

func dist(_ a: Vec, _ b: Vec) -> Double {
    let d = a - b
    return (d * d).sum().squareRoot()
}

/// Clamp a top-left so the window is fully inside one screen; pinned top-left if it cannot.
func clamp(_ pos: Vec, _ size: Vec, _ s: Rect) -> Vec {
    Vec(max(s.x, min(pos.x, s.x + s.w - size.x)), max(s.y, min(pos.y, s.y + s.h - size.y)))
}

func overlap(_ pos: Vec, _ size: Vec, _ s: Rect) -> Double {
    let w = min(pos.x + size.x, s.x + s.w) - max(pos.x, s.x)
    let h = min(pos.y + size.y, s.y + s.h) - max(pos.y, s.y)
    return max(w, 0) * max(h, 0)
}

/// Keep the window fully inside the screens, where it may straddle two that touch.
///
/// Screens never overlap, so the window is inside their union exactly when its overlaps add up to
/// its whole area. Otherwise (a dead corner between unequal monitors, or past the edge) it moves to
/// the nearest spot inside a single screen; pinned top-left if it fits on none.
public func fit(_ pos: Vec, _ size: Vec, _ screens: [Rect]) -> Vec {
    if screens.reduce(0, { $0 + overlap(pos, size, $1) }) >= size.x * size.y - 1e-3 { return pos }
    return screens.map { clamp(pos, size, $0) }.min { dist($0, pos) < dist($1, pos) } ?? pos
}

/// A random top-left in the margin band along the bottom, left or right edge of one screen.
public func pickTarget<G: RandomNumberGenerator>(_ rng: inout G, _ screen: Rect, _ size: Vec) -> Vec {
    let right = screen.x + screen.w - size.x
    let bottom = screen.y + screen.h - size.y
    var x = uniform(screen.x, right, &rng)
    var y = uniform(screen.y, bottom, &rng)
    switch Int.random(in: 0..<3, using: &rng) {
    case 0: y = uniform(bottom - Roam.margin, bottom, &rng)
    case 1: x = uniform(screen.x, screen.x + Roam.margin, &rng)
    default: x = uniform(right - Roam.margin, right, &rng)
    }
    return clamp(Vec(x, y), size, screen)
}

/// Moves the window like a pet: rest, drift (to any screen), sleep in a corner, stay when needed.
public final class Roamer {
    public enum Mode: String { case none = "", rest, drift, present, held, sleep }

    public private(set) var screens: [Rect]
    public private(set) var size: Vec
    public var pos = Vec.zero  // the app sets it after a resize, to keep the face where it was
    public var mode = Mode.none
    public var goal = Vec.zero
    public var heldUntil = -Double.infinity
    var rng: SplitMix64
    var last: Double?
    var restUntil = 0.0
    var origin = Vec.zero
    var trip = 0.0
    var elapsed = 0.0

    public init(screens: [Rect], size: Vec, seed: UInt64? = nil, start: Vec? = nil) {
        precondition(!screens.isEmpty, "a Roamer needs at least one screen")
        rng = SplitMix64(seed: seed ?? UInt64.random(in: .min ... .max))
        self.screens = screens
        self.size = size
        pos = start ?? .zero  // `bed` needs it: the corner of the screen it is on
        pos = fit(start ?? bed(), size, screens)
        origin = pos
        goal = pos
    }

    /// -1 / 1 while drifting left / right, else 0: where its eyes should lead.
    public var heading: Int {
        let dx = goal.x - pos.x
        return mode == .drift ? (dx > 8 ? 1 : 0) - (dx < -8 ? 1 : 0) : 0
    }

    public func resize(_ size: Vec) {
        self.size = size
        pos = fit(pos, size, screens)
    }

    public func setScreens(_ screens: [Rect]) {
        precondition(!screens.isEmpty, "a Roamer needs at least one screen")
        self.screens = screens
        pos = fit(pos, size, screens)
    }

    /// The user dropped it at `pos`: stay there for `seconds`.
    public func hold(now: Double, pos: Vec, seconds: Double = Roam.hold) {
        self.pos = fit(pos, size, screens)
        heldUntil = now + seconds
    }

    /// Advance to `now`; return the window's top-left.
    public func step(now: Double, asleep: Bool, engaged: Bool) -> IVec {
        let dt = last.map { min(max(now - $0, 0), Roam.maxDT) } ?? 0
        last = now
        if engaged {
            mode = .present
        } else if now < heldUntil {
            mode = .held
        } else if asleep {
            if mode != .sleep || goal != bed() { go(bed()) }
            mode = .sleep
            _ = travel(dt)
        } else {
            wander(now, dt)
        }
        pos = fit(pos, size, screens)
        // Python rounds half to even; so do we, to keep both builds on the same pixel.
        return IVec(Int(pos.x.rounded(.toNearestOrEven)), Int(pos.y.rounded(.toNearestOrEven)))
    }

    private func wander(_ now: Double, _ dt: Double) {
        if mode != .rest && mode != .drift { startRest(now) }
        if mode == .rest && now >= restUntil {
            go(pickTarget(&rng, screens.randomElement(using: &rng)!, size))
            mode = .drift
        }
        if mode == .drift && travel(dt) { startRest(now) }
    }

    private func startRest(_ now: Double) {
        mode = .rest
        restUntil = now + uniform(Roam.rest.lowerBound, Roam.rest.upperBound, &rng)
    }

    /// The bottom-right corner of the screen it is on, so a nap never needs a long walk.
    private func bed() -> Vec {
        let s = screens.max { overlap(pos, size, $0) < overlap(pos, size, $1) }!
        return clamp(Vec(s.x + s.w - size.x - Roam.edge, s.y + s.h - size.y - Roam.edge), size, s)
    }

    private func go(_ target: Vec) {
        origin = pos
        goal = target
        elapsed = 0
        trip = dist(pos, target) / Roam.speed
    }

    /// Ease from origin toward goal; true on arrival.
    private func travel(_ dt: Double) -> Bool {
        elapsed += dt
        let p = trip > 0 ? min(1, elapsed / trip) : 1
        let e = p * p * (3 - 2 * p)
        pos = origin * (1 - e) + goal * e
        return p >= 1
    }
}
