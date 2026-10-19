// Whether the card is light or dark, decided by what is behind it. Pure: the UI hands in the mean luma of the screen
// under the card (a few times a second) and the clock's dt; this decides the target with a hysteresis, eases toward it
// and says how the ink should read. `level` 0 = a dark card with light ink, 1 = a light card with dark ink (a light card
// over a dark backdrop and the other way round, so the card always stands out from what it floats on).
import Foundation

public struct Shade: Equatable {
    public static let lightBelow = 0.42  // a backdrop darker than this wants a light card
    public static let darkAbove = 0.58  // one brighter than this wants a dark card; in between the card keeps what it has
    public static let tau = 0.12  // s: time constant of the ease
    public static let forget = 3  // consecutive looks that failed before the card goes back to the system's look

    /// Where the card is now (0...1): what the glass crossfade shows.
    public internal(set) var level = 0.0
    /// Where it is going.
    public private(set) var target = 0.0
    /// False until a look succeeded, and again after `forget` failed ones: the UI keeps the system's own look.
    public private(set) var known = false
    private var misses = 0

    public init() {}

    public var moving: Bool { level != target }

    /// The ink's own level: the same 0...1 but steep around the middle, so the text flips over quickly instead of
    /// fading through a grey that reads on neither glass.
    public var ink: Double {
        let t = min(max((level - 0.35) / 0.3, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// One look at the backdrop: its mean luma, or nil when there was none (no permission, an error).
    public mutating func see(luma: Double?) {
        guard let luma else {
            misses += 1
            if misses >= Self.forget { known = false }  // one failed capture must not flip the card to another look
            return
        }
        misses = 0
        if luma < Self.lightBelow {
            target = 1
        } else if luma > Self.darkAbove {
            target = 0
        } else if !known {
            target = luma < 0.5 ? 1 : 0  // nothing to keep yet
        }
        if !known {
            known = true
            level = target  // the first look has no earlier look to ease from
        }
    }

    /// Ease `dt` seconds toward the target; true while still moving (within 0.01 of it the level snaps there).
    public mutating func step(dt: Double) -> Bool {
        guard level != target else { return false }
        level += (target - level) * (1 - exp(-max(0, dt) / Self.tau))
        if abs(target - level) < 0.01 {
            level = target
            return false
        }
        return true
    }

    /// Arrive now (Reduce Motion).
    public mutating func snap() { level = target }

    /// The mean luma (0...1) of a BGRA image, on the gamma-encoded values; nil for an empty or short buffer.
    public static func meanLuma(bgra: [UInt8], width: Int, height: Int) -> Double? {
        let n = width * height
        guard n > 0, bgra.count >= n * 4 else { return nil }
        var sum = 0.0
        for i in 0..<n {
            sum += 0.0722 * Double(bgra[4 * i]) + 0.7152 * Double(bgra[4 * i + 1]) + 0.2126 * Double(bgra[4 * i + 2])
        }
        return sum / (255 * Double(n))
    }
}
