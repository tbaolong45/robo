// The look of the speech card: one theme, Liquid Glass, plus the user's theme.json. A pure value layer on purpose
// (the face background is "#rrggbb" strings, computed colours are `RGBA`), so the UI maps it to NSColor and nothing
// here needs a display. The card and the chat are native glass in neutral ink only, so the one colour left here is the
// face's own body. `Theme` is the token table, `Themes` the module.
//
// ~/.config/robo/theme.json is configuration the user may hand-edit (state lives in ~/.local/share/robo);
// every key is optional:
//
//     {"tokens": {"bot_name": "Pixel", "cps": 80, "caret": "bar"}}
//
// Each token is checked on its own: a bad one (or a token of the old HUD themes, or a "theme" key) is skipped, the
// rest still applies, and a missing or broken file gives plain Liquid Glass. Token names stay snake_case.
import Foundation

/// A computed colour, each channel 0...255.
public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
}

/// One flat token table; the defaults are Liquid Glass. Outside RoboCore the tokens are read-only.
public struct Theme: Equatable, Sendable {
    public struct FaceBG: Equatable, Sendable {
        public var centre: String, edge: String
        init(_ centre: String, _ edge: String) { self.centre = centre; self.edge = edge }
    }

    public internal(set) var key = "glass"
    public internal(set) var label = "Liquid Glass"
    public internal(set) var faceBg = FaceBG("#ffffff", "#f6f7f9")  // the face's white body: highlight, edge
    // text
    public internal(set) var textPx = 14
    public internal(set) var lineH = 116  // percent of the toolkit's line spacing
    // typing
    public internal(set) var cps = 55.0  // characters per second, 0 = instant
    public internal(set) var caret = "block"  // block | bar | under
    public internal(set) var caretMs = 530
    // the bot
    public internal(set) var botName = "Robo"

    /// This theme with `edit` applied.
    func with(_ edit: (inout Theme) -> Void) -> Theme {
        var t = self
        edit(&t)
        return t
    }
}

public enum Themes {
    public static let glass = Theme()

    // MARK: the user's file

    /// $XDG_CONFIG_HOME/robo/theme.json, else ~/.config/robo/theme.json (an empty variable counts as unset).
    public static func configPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("robo/theme.json")
    }

    private static let reals: [String: (WritableKeyPath<Theme, Double>, ClosedRange<Double>)] = [
        "cps": (\.cps, 0...400)]
    private static let ints: [String: (WritableKeyPath<Theme, Int>, ClosedRange<Int>)] = [
        "text_px": (\.textPx, 12...18), "line_h": (\.lineH, 105...150), "caret_ms": (\.caretMs, 300...1000)]
    private static let enums: [String: (WritableKeyPath<Theme, String>, [String])] = [
        "caret": (\.caret, ["block", "bar", "under"])]
    private static let texts: [String: WritableKeyPath<Theme, String>] = ["bot_name": \.botName]  // up to 12 characters, not blank

    private static func isHex(_ v: String) -> Bool {
        let u = Array(v.unicodeScalars)
        return u.count == 7 && u[0] == "#" && u[1...].allSatisfy { $0.isASCII && Character($0).isHexDigit }
    }

    /// A JSON number as a finite Double; true and false are not numbers.
    private static func number(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    /// Set token `name` to `v` in `t` if `v` is acceptable. label and key are in no table, so they can never be overridden.
    private static func apply(_ name: String, _ v: Any, in t: inout Theme) {
        if let (path, r) = reals[name] {
            if let d = number(v) { t[keyPath: path] = min(r.upperBound, max(r.lowerBound, d)) }
        } else if let (path, r) = ints[name] {
            if let d = number(v) { t[keyPath: path] = Int(min(Double(r.upperBound), max(Double(r.lowerBound), d)).rounded()) }
        } else if name == "face_bg" {
            if let a = v as? [String], a.count == 2, isHex(a[0]), isHex(a[1]) { t.faceBg = Theme.FaceBG(a[0], a[1]) }
        } else if let (path, allowed) = enums[name] {
            if let s = v as? String, allowed.contains(s) { t[keyPath: path] = s }
        } else if let path = texts[name] {
            let blank = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            if let s = v as? String, s.unicodeScalars.count <= 12, !s.trimmingCharacters(in: blank).isEmpty { t[keyPath: path] = s }
        }
    }

    /// Liquid Glass with the valid entries of `tokens` on top; a bad token never costs the user the others.
    static func resolve(_ tokens: Any?) -> Theme {
        guard let tokens = tokens as? [String: Any] else { return glass }
        var t = glass
        for (name, value) in tokens { apply(name, value, in: &t) }
        return t
    }

    /// The theme the file asks for, always a valid one: unreadable, not JSON or not an object gives plain glass.
    public static func load(path: URL = configPath()) -> Theme {
        let json = (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return resolve(json?["tokens"])
    }

    /// Modification time of the file in ns, 0 if there is none: "did the user edit it?".
    public static func stamp(path: URL = configPath()) -> Int {
        var st = stat()
        guard stat(path.path, &st) == 0 else { return 0 }
        return Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int(st.st_mtimespec.tv_nsec)
    }

    // MARK: colours

    /// A "#rrggbb" token as RGBA.
    public static func rgba(_ colour: String, alpha: Double = 1) -> RGBA {
        let u = Array(colour.unicodeScalars)
        func byte(_ at: Int) -> UInt8 { UInt8(String(String.UnicodeScalarView(u[at..<at + 2])), radix: 16)! }
        return RGBA(r: byte(1), g: byte(3), b: byte(5), a: alpha8(alpha))
    }

    /// A NaN alpha is opaque: a colour must still come out.
    private static func alpha8(_ alpha: Double) -> UInt8 {
        alpha.isNaN ? 255 : UInt8(min(255, max(0, (255 * alpha).rounded(.toNearestOrEven))))
    }
}
