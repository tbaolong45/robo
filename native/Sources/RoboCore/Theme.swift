// The look of the speech card: one theme, Liquid Glass, plus the user's theme.json. A pure value layer on purpose
// (the face background is "#rrggbb" strings, computed colours are `RGBA`), so the UI maps it to NSColor and nothing
// here needs a display. The card itself is native glass: its fill, its text and its status lights are the system's
// (they follow light and dark and whatever is behind the glass), so the only colours left here are the accent
// the face's mood paints (`accent`) and the face's own screen. `Theme` is the token table, `Themes` the module.
// The Python build keeps the five HUD themes of src/robo/theme.py; this is not a port of it any more.
//
// ~/.config/robo/theme.json is configuration the user may hand-edit (state lives in ~/.local/share/robo);
// every key is optional:
//
//     {"tokens": {"bot_name": "PIXEL", "hue": 300, "cps": 80, "caret": "bar"}}
//
// Each token is checked on its own: a bad one (or a token of the old HUD themes, or a "theme" key) is skipped, the
// rest still applies, and a missing or broken file gives plain Liquid Glass. Token names stay snake_case.
import Foundation

/// A computed colour, each channel 0...255.
public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
}

/// One flat token table; the defaults are Liquid Glass. Outside RoboCore the tokens are read-only, and every
/// theme made inside gets a new `rev`, so a cache keyed on `rev` never serves a stale theme: two themes
/// with different tokens never share one (a plain copy has the same tokens and so the same `rev`).
public struct Theme: Equatable, Sendable {
    public struct FaceBG: Equatable, Sendable {
        public var centre: String, edge: String
        init(_ centre: String, _ edge: String) { self.centre = centre; self.edge = edge }
    }

    /// Changes with every new Theme (also through `with`). Not part of ==.
    struct Revision: Equatable, Sendable {
        let value = Revision.next()
        static func == (_: Revision, _: Revision) -> Bool { true }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var last = 0
        private static func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            last += 1
            return last
        }
    }

    public internal(set) var key = "glass"
    public internal(set) var label = "Liquid Glass"
    // accent: HSV(live hue, accS, accV): the tint of the glass, the lights, the caret and the dots
    public internal(set) var hue = 188.0  // resting hue of the face and of the accent
    public internal(set) var accS = 0.85
    public internal(set) var accV = 1.0
    public internal(set) var followEmotion = true  // the card's accent follows the face's live hue (error: always)
    public internal(set) var faceBg = FaceBG("#121a2a", "#090d16")  // face screen: centre, edge
    // text
    public internal(set) var textPx = 14
    public internal(set) var lineH = 116  // percent of the toolkit's line spacing
    // typing
    public internal(set) var cps = 55.0  // characters per second, 0 = instant
    public internal(set) var caret = "block"  // block | bar | under
    public internal(set) var caretMs = 530
    // the bot
    public internal(set) var botName = "ROBO"
    public internal(set) var modelChip = ""  // "" = what `robo setup` configured, spaces only = no chip
    var revision = Revision()

    public var rev: Int { revision.value }

    /// This theme with `edit` applied, and a new `rev`.
    func with(_ edit: (inout Theme) -> Void) -> Theme {
        var t = self
        edit(&t)
        t.revision = Revision()
        return t
    }
}

public enum Themes {
    public static let faceBaseHue = 188.0  // FaceParams.hue: what every neutral pose has (tests pin it to the face)
    public static let errorHue = 356.0  // expressions.ACTIVITY["error"]
    public static let separation = 14.0  // degrees a signal emotion keeps from the theme's resting hue

    public static let glass = Theme()

    // MARK: the user's file

    /// $XDG_CONFIG_HOME/robo/theme.json, else ~/.config/robo/theme.json (an empty variable counts as unset).
    public static func configPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("robo/theme.json")
    }

    private static let reals: [String: (WritableKeyPath<Theme, Double>, ClosedRange<Double>)] = [
        "acc_s": (\.accS, 0...1), "acc_v": (\.accV, 0.3...1), "cps": (\.cps, 0...400)]
    private static let ints: [String: (WritableKeyPath<Theme, Int>, ClosedRange<Int>)] = [
        "text_px": (\.textPx, 12...18), "line_h": (\.lineH, 105...150), "caret_ms": (\.caretMs, 300...1000)]
    private static let enums: [String: (WritableKeyPath<Theme, String>, [String])] = [
        "caret": (\.caret, ["block", "bar", "under"])]
    private static let bools: [String: WritableKeyPath<Theme, Bool>] = ["follow_emotion": \.followEmotion]
    private static let texts: [String: WritableKeyPath<Theme, String>] = [  // up to 12 characters; botName also not blank
        "bot_name": \.botName, "model_chip": \.modelChip]

    private static func isHex(_ v: String) -> Bool {
        let u = Array(v.unicodeScalars)
        return u.count == 7 && u[0] == "#" && u[1...].allSatisfy { $0.isASCII && Character($0).isHexDigit }
    }

    /// Set token `name` to `v` in `t`; false (and `t` untouched) when `v` is not acceptable. label, key and rev are
    /// in no table, so they can never be overridden.
    private static func apply(_ name: String, _ v: PyJSON, in t: inout Theme) -> Bool {
        if name == "hue" || reals[name] != nil || ints[name] != nil {
            switch v {
            case .int(let n):
                if name == "hue" { t.hue = Double(((n % 360) + 360) % 360) }
                else if let (path, r) = reals[name] { t[keyPath: path] = min(r.upperBound, max(r.lowerBound, Double(n))) }
                else if let (path, r) = ints[name] { t[keyPath: path] = min(r.upperBound, max(r.lowerBound, n)) }
            case .big(let digits):  // too big for an Int: it only ever lands on a bound (or wraps, for hue)
                let negative = digits.hasPrefix("-")
                if name == "hue" {
                    let m = digits.dropFirst(negative ? 1 : 0).reduce(0) { ($0 * 10 + Int(String($1))!) % 360 }
                    t.hue = Double(negative ? (360 - m) % 360 : m)
                } else if let (path, r) = reals[name] { t[keyPath: path] = negative ? r.lowerBound : r.upperBound }
                else if let (path, r) = ints[name] { t[keyPath: path] = negative ? r.lowerBound : r.upperBound }
            case .double(let d) where d.isFinite:
                if name == "hue" { t.hue = pyFloatMod(d, 360) }
                else if let (path, r) = reals[name] { t[keyPath: path] = min(r.upperBound, max(r.lowerBound, d)) }
                else if let (path, r) = ints[name] {
                    t[keyPath: path] = Int(min(Double(r.upperBound), max(Double(r.lowerBound), d)).rounded(.toNearestOrEven))
                }
            default: return false
            }
            return true
        }
        if name == "face_bg" {
            guard case .array(let a) = v, a.count == 2, case .string(let c) = a[0], case .string(let e) = a[1],
                  isHex(c), isHex(e) else { return false }
            t.faceBg = Theme.FaceBG(c, e)
        } else if let (path, allowed) = enums[name] {
            guard case .string(let s) = v, allowed.contains(where: { $0.utf8.elementsEqual(s.utf8) }) else { return false }
            t[keyPath: path] = s
        } else if let path = bools[name] {
            guard case .bool(let b) = v else { return false }
            t[keyPath: path] = b
        } else if let path = texts[name] {
            guard case .string(let s) = v, s.unicodeScalars.count <= 12,
                  name != "bot_name" || s.unicodeScalars.contains(where: { !$0.isPySpace }) else { return false }
            t[keyPath: path] = s
        } else {
            return false
        }
        return true
    }

    /// Liquid Glass with the valid entries of `tokens` on top.
    static func resolve(_ tokens: PyJSON?) -> Theme {
        guard case .object(let pairs)? = tokens else { return glass }
        var t = glass
        var any = false
        for (name, value) in pairs where apply(name, value, in: &t) { any = true }  // a bad token never costs the user the others
        return any ? t.with { _ in } : glass
    }

    /// The theme the file asks for, always a valid one.
    public static func load(path: URL = configPath()) -> Theme { resolve(readObject(path)?.get("tokens")) }

    /// The file as a JSON object, nil when it is unreadable, not UTF-8, not JSON or not an object.
    private static func readObject(_ path: URL) -> PyJSON? {
        guard let bytes = try? Data(contentsOf: path), let text = PyJSON.decodeUTF8(bytes),
              let json = try? PyJSON.parse(text), case .object = json else { return nil }
        return json
    }

    /// Modification time of the file in ns, 0 if there is none: "did the user edit it?".
    public static func stamp(path: URL = configPath()) -> Int {
        var st = stat()
        guard stat(path.path, &st) == 0 else { return 0 }
        return Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int(st.st_mtimespec.tv_nsec)
    }

    /// Text of the header's model chip ("" = hide it): the token, else the configured model
    /// (`model.default` of `robo setup`, not a live reading from Hermes).
    public static func chipText(_ t: Theme, configuredModel: String) -> String {
        if !t.modelChip.isEmpty { return pyStrip(t.modelChip) }
        return configuredModel.hasPrefix("claude-") ? String(configuredModel.dropFirst(7)) : configuredModel
    }

    // MARK: colours

    /// A "#rrggbb" token as RGBA.
    public static func rgba(_ colour: String, alpha: Double = 1) -> RGBA {
        let u = Array(colour.unicodeScalars)
        func byte(_ at: Int) -> UInt8 { UInt8(String(String.UnicodeScalarView(u[at..<at + 2])), radix: 16)! }
        return RGBA(r: byte(1), g: byte(3), b: byte(5), a: alpha8(alpha))
    }

    /// A NaN alpha is opaque (Python raises; a colour must still come out).
    private static func alpha8(_ alpha: Double) -> UInt8 {
        alpha.isNaN ? 255 : UInt8(min(255, max(0, (255 * alpha).rounded(.toNearestOrEven))))
    }

    private static func hsv(_ hue: Double, _ s: Double, _ v: Double, _ alpha: Double) -> RGBA {
        let h = pyFloatMod(hue.isFinite ? hue : 0, 360) / 360  // colorsys.hsv_to_rgb; a NaN or infinite hue is 0 (Python raises)
        let r, g, b: Double
        if s == 0 {
            (r, g, b) = (v, v, v)
        } else {
            let i = Int(h * 6)
            let f = h * 6 - Double(i)
            let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
            switch i % 6 {
            case 0: (r, g, b) = (v, t, p)
            case 1: (r, g, b) = (q, v, p)
            case 2: (r, g, b) = (p, v, t)
            case 3: (r, g, b) = (p, q, v)
            case 4: (r, g, b) = (t, p, v)
            default: (r, g, b) = (v, p, q)
            }
        }
        func c(_ x: Double) -> UInt8 { UInt8((255 * x).rounded(.toNearestOrEven)) }
        return RGBA(r: c(r), g: c(g), b: c(b), a: alpha8(alpha))
    }

    /// The glass tint, lights, caret and dots at `hue` (the live hue; see `liveHue`).
    public static func accent(_ t: Theme, _ hue: Double, alpha: Double = 1) -> RGBA { hsv(hue, t.accS, t.accV, alpha) }

    // MARK: hues

    /// The hue the face takes in this theme. `base` is what expressions.target() gives (188 neutral, 168
    /// happy, 176 calm, 44 proud, 318 playful, 34 concerned, 216 sad, 356 error).
    ///
    /// Error is always red. Neutral poses and the two quiet moods (happy, calm) are offsets from the
    /// theme's resting hue, so the default reproduces today's face exactly. The signal emotions keep their own
    /// hue (proud stays gold, sad blue) but are pushed `separation` degrees away when they land that
    /// close to the resting hue, so they still differ from neutral.
    public static func hueFor(_ t: Theme, activity: String, emotion: String, base: Double) -> Double {
        if activity == "error" || base == errorHue { return base }
        if abs(base - faceBaseHue) < 1e-6 || emotion == "happy" || emotion == "calm" {
            return pyFloatMod(t.hue + base - faceBaseHue, 360)
        }
        let gap = pyFloatMod(base - t.hue + 180, 360) - 180
        if abs(gap) < separation {
            return pyFloatMod(t.hue + copysign(separation, gap == 0 ? 1 : gap), 360)
        }
        return base
    }

    /// The hue the card paints with: the face's current (animated) one when the theme follows the mood,
    /// else the resting hue. An error always turns the card red.
    public static func liveHue(_ t: Theme, faceNow: Double, activity: String) -> Double {
        pyFloatMod(t.followEmotion || activity == "error" ? faceNow : t.hue, 360)
    }
}

/// Python's float `%`: the result takes the sign of the divisor (so -1e-20 % 360 is 360.0, as in Python).
func pyFloatMod(_ a: Double, _ b: Double) -> Double {
    var m = fmod(a, b)
    if m == 0 { return copysign(0, b) }
    if (b < 0) != (m < 0) { m += b }
    return m
}

/// `str.strip()`: Python's idea of whitespace, not Swift's.
func pyStrip(_ s: String) -> String {
    let u = Array(s.unicodeScalars)
    guard let first = u.firstIndex(where: { !$0.isPySpace }), let last = u.lastIndex(where: { !$0.isPySpace }) else { return "" }
    return String(String.UnicodeScalarView(u[first...last]))
}
