// Colours, shape and typing speed of the speech bubble: five themes plus the user's theme.json.
// Port of src/robo/theme.py. A pure value layer on purpose (colour tokens are "#rrggbb" strings, computed
// colours are `RGBA`), so the UI maps it to NSColor and nothing here needs a display. `Theme` is the token
// table, `Themes` is the module: the five presets, the file and the colour and hue maths.
//
// ~/.config/robo/theme.json is configuration the user may hand-edit (state lives in ~/.local/share/robo);
// every key is optional:
//
//     {"theme": "matrix", "tokens": {"bot_name": "PIXEL", "hue": 300, "cps": 80, "caret": "bar"}}
//
// `tokens` overrides single tokens of the chosen theme. Each token is checked on its own: a bad one is
// skipped, the rest still applies, and a missing or broken file gives plain Cyan HUD. The right-click
// menu only ever writes the `theme` key (`Themes.saveChoice`). Token names in the file stay snake_case.
import Foundation

/// A computed colour, each channel 0...255.
public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
}

/// One flat token table; the defaults are Cyan HUD. Outside RoboCore the tokens are read-only, and every
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

    public internal(set) var key = "cyan"
    public internal(set) var label = "Cyan HUD"
    public internal(set) var dark = true
    // accent: HSV(live hue, accS, accV); small labels use the paler labS / labV so they hold their
    // contrast on every hue
    public internal(set) var hue = 188.0  // resting hue of the face and of the accent
    public internal(set) var accS = 0.85
    public internal(set) var accV = 1.0
    public internal(set) var labS = 0.40
    public internal(set) var labV = 0.88
    public internal(set) var followEmotion = true  // the card's accent follows the face's live hue (error: always)
    public internal(set) var faceBg = FaceBG("#121a2a", "#090d16")  // face screen: centre, edge
    // card surface
    public internal(set) var bgTop = "#0b1322"
    public internal(set) var bgBot = "#0e182b"
    public internal(set) var bgA = 0.93  // at least .90: the window cannot blur the wallpaper behind it
    public internal(set) var sheen = 0.05
    public internal(set) var scanA = 0.16
    public internal(set) var scanPx = 3
    public internal(set) var scanC = "#000000"
    public internal(set) var gridA = 0.0
    public internal(set) var aura = 0.0
    public internal(set) var auraDh = 0.0
    // frame
    public internal(set) var shape = "cut"  // cut | round
    public internal(set) var corner = 9
    public internal(set) var borderA = 0.55
    public internal(set) var glow = 1.0
    public internal(set) var brLen = 15
    public internal(set) var brW = 1.6
    public internal(set) var radius = 3  // chips, model chip, wells, input
    // text
    public internal(set) var text = "#e6efff"
    public internal(set) var textDim = "#a6b8d8"
    public internal(set) var head = "#9fe9ff"
    public internal(set) var link = "#7fd0ff"
    public internal(set) var codeBg = "#050a13"
    public internal(set) var codeFg = "#c4d4f0"
    public internal(set) var inlineBg = "#16253d"
    public internal(set) var onAccent = "#04121a"
    public internal(set) var ledOk = "#3ddc8a"
    public internal(set) var ledWarn = "#ffb62e"
    public internal(set) var ledBad = "#ff5468"
    public internal(set) var bodyMono = false
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
    public static let pink = 330.0  // where an aura's bloom and border sweep drift to

    public static let cyan = Theme()
    // Matrix labV is .88, the spec's .86 left the label at 4.38:1 on the blue the hue passes through
    // while the animator sweeps (ThemeTests checks all 360 hues).
    public static let matrix = Theme(
        key: "matrix", label: "Matrix", hue: 128, accS: 0.88, labS: 0.45, labV: 0.88,
        faceBg: .init("#04140a", "#010603"), bgTop: "#04100a", bgBot: "#051409", bgA: 0.94,
        sheen: 0.03, scanA: 0.28, gridA: 0.07, corner: 0, borderA: 0.60, glow: 0.8, brLen: 13,
        brW: 2.0, radius: 0, text: "#c9f6d3", textDim: "#86c99a", head: "#7dff9e", link: "#6bf0c8",
        codeBg: "#020a05", codeFg: "#a9e8b8", inlineBg: "#0f2a18", onAccent: "#02140a",
        ledOk: "#4dff88", ledWarn: "#ffc640", ledBad: "#ff5a5a", bodyMono: true, textPx: 13,
        lineH: 114, cps: 70)
    public static let amber = Theme(
        key: "amber", label: "Amber CRT", hue: 38, accS: 0.95, labS: 0.45, labV: 0.92,
        faceBg: .init("#1c1004", "#0b0601"), bgTop: "#150d05", bgBot: "#1a1007", bgA: 0.94,
        sheen: 0.04, scanA: 0.30, shape: "round", corner: 14, borderA: 0.62, glow: 1.35, brLen: 17,
        brW: 1.8, radius: 5, text: "#ffdca8", textDim: "#d7a868", head: "#ffc45c", link: "#ffd27a",
        codeBg: "#0c0703", codeFg: "#f0c98f", inlineBg: "#33200b", onAccent: "#1a0e00",
        ledOk: "#8dff6a", ledWarn: "#ffd23a", ledBad: "#ff5a4a", bodyMono: true, textPx: 13,
        lineH: 114, cps: 40, caretMs: 620)
    public static let aurora = Theme(
        key: "aurora", label: "Violet Aurora", hue: 268, accS: 0.72, labS: 0.30, labV: 0.92,
        faceBg: .init("#1a1233", "#0b0719"), bgTop: "#150d2a", bgBot: "#1b1136", sheen: 0.07,
        scanA: 0.07, aura: 0.16, auraDh: 70, shape: "round", corner: 16, borderA: 0.66, glow: 1.25,
        brLen: 18, brW: 1.5, radius: 8, text: "#efe8ff", textDim: "#baa9e3", head: "#d8c4ff",
        link: "#b9a2ff", codeBg: "#0c0720", codeFg: "#d5c8f7", inlineBg: "#2a1c52",
        onAccent: "#150a33", cps: 50)
    public static let daylight = Theme(
        key: "daylight", label: "Daylight", dark: false, hue: 196, accS: 0.88, accV: 0.60,
        labS: 0.88, labV: 0.42, faceBg: .init("#1a2a44", "#0c1424"), bgTop: "#f7fbff",
        bgBot: "#e9f1fa", bgA: 0.96, sheen: 0.55, scanA: 0.035, scanC: "#0a2a4a", shape: "round",
        corner: 12, borderA: 0.70, glow: 0.45, brLen: 14, brW: 1.7, radius: 6, text: "#13223a",
        textDim: "#4a5f80", head: "#0a6a8a", link: "#0b63c4", codeBg: "#dde8f4",
        codeFg: "#24344f", inlineBg: "#d3e3f3", onAccent: "#ffffff", ledOk: "#12a05a",
        ledWarn: "#c77700", ledBad: "#d42a3d")

    /// The picker's order.
    public static let all = [cyan, matrix, amber, aurora, daylight]

    // MARK: the user's file

    /// $XDG_CONFIG_HOME/robo/theme.json, else ~/.config/robo/theme.json (an empty variable counts as unset).
    public static func configPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("robo/theme.json")
    }

    private static let colours: [String: WritableKeyPath<Theme, String>] = [
        "bg_top": \.bgTop, "bg_bot": \.bgBot, "scan_c": \.scanC, "text": \.text, "text_dim": \.textDim,
        "head": \.head, "link": \.link, "code_bg": \.codeBg, "code_fg": \.codeFg, "inline_bg": \.inlineBg,
        "on_accent": \.onAccent, "led_ok": \.ledOk, "led_warn": \.ledWarn, "led_bad": \.ledBad]
    private static let reals: [String: (WritableKeyPath<Theme, Double>, ClosedRange<Double>)] = [
        "acc_s": (\.accS, 0...1), "acc_v": (\.accV, 0.3...1), "lab_s": (\.labS, 0...1), "lab_v": (\.labV, 0...1),
        "grid_a": (\.gridA, 0...1), "bg_a": (\.bgA, 0.90...1), "sheen": (\.sheen, 0...0.6),
        "scan_a": (\.scanA, 0...0.4), "aura": (\.aura, 0...0.3), "aura_dh": (\.auraDh, 0...120),
        "border_a": (\.borderA, 0.2...1), "glow": (\.glow, 0...1.6), "br_w": (\.brW, 0.8...3),
        "cps": (\.cps, 0...400)]
    private static let ints: [String: (WritableKeyPath<Theme, Int>, ClosedRange<Int>)] = [
        "scan_px": (\.scanPx, 2...8), "corner": (\.corner, 0...24), "br_len": (\.brLen, 0...30),
        "radius": (\.radius, 0...12), "text_px": (\.textPx, 12...18), "line_h": (\.lineH, 105...150),
        "caret_ms": (\.caretMs, 300...1000)]
    private static let enums: [String: (WritableKeyPath<Theme, String>, [String])] = [
        "shape": (\.shape, ["cut", "round"]), "caret": (\.caret, ["block", "bar", "under"])]
    private static let bools: [String: WritableKeyPath<Theme, Bool>] = [
        "follow_emotion": \.followEmotion, "body_mono": \.bodyMono]
    private static let texts: [String: WritableKeyPath<Theme, String>] = [  // up to 12 characters; botName also not blank
        "bot_name": \.botName, "model_chip": \.modelChip]

    private static func isHex(_ v: String) -> Bool {
        let u = Array(v.unicodeScalars)
        return u.count == 7 && u[0] == "#" && u[1...].allSatisfy { $0.isASCII && Character($0).isHexDigit }
    }

    /// Set token `name` to `v` in `t`; false (and `t` untouched) when `v` is not acceptable. label, dark,
    /// key and rev are in no table, so they can never be overridden.
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
        if let path = colours[name] {
            guard case .string(let s) = v, isHex(s) else { return false }
            t[keyPath: path] = s
        } else if name == "face_bg" {
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

    /// Theme `key` (unknown, or not a string: Cyan HUD) with the valid entries of `tokens` on top.
    static func resolve(_ key: PyJSON?, _ tokens: PyJSON?) -> Theme {
        var base = cyan
        if case .string(let k)? = key, let found = all.first(where: { $0.key.utf8.elementsEqual(k.utf8) }) { base = found }
        guard case .object(let pairs)? = tokens else { return base }
        var t = base
        var any = false
        for (name, value) in pairs where apply(name, value, in: &t) { any = true }  // a bad token never costs the user the others
        return any ? t.with { _ in } : base
    }

    /// The theme the file asks for, always a valid one. `choice` (a menu pick) replaces the file's
    /// `theme` key but keeps its `tokens`, so a pick still applies when saving it failed.
    public static func load(path: URL = configPath(), choice: String? = nil) -> Theme {
        let data = readObject(path)
        let picked = choice.flatMap { $0.isEmpty ? nil : PyJSON.string($0) }
        return resolve(picked ?? data?.get("theme"), data?.get("tokens"))
    }

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

    /// Remember the picked theme, keeping every other key. False (nothing written, the theme still applies
    /// for this run) when the file cannot be written or is not a JSON object we can keep: a half-edited
    /// file is the user's, never overwrite it.
    @discardableResult
    public static func saveChoice(_ key: String, path: URL = configPath()) -> Bool {
        guard all.contains(where: { $0.key == key }) else { return false }
        let target = path.resolvingSymlinksInPath()  // a symlinked (dotfiles) file is updated, not replaced
        var pairs: [(key: String, value: PyJSON)] = []
        if let bytes = try? Data(contentsOf: target) {
            guard let raw = PyJSON.decodeUTF8(bytes) else { return false }
            if raw.unicodeScalars.contains(where: { !$0.isPySpace }) {
                guard let json = try? PyJSON.parse(raw), case .object(let p) = json else { return false }
                pairs = p
            }
        } else if FileManager.default.fileExists(atPath: target.path) {
            return false  // there, but unreadable
        }
        if let at = pairs.firstIndex(where: { $0.key == "theme" }) { pairs[at].value = .string(key) }
        else { pairs.append(("theme", .string(key))) }
        let tmp = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".tmp")
        defer { unlink(tmp.path) }  // nothing to do after a successful rename
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((PyJSON.object(pairs).dumps(indent: 2) + "\n").utf8).write(to: tmp)
        } catch {
            return false
        }
        return rename(tmp.path, target.path) == 0  // atomic: a crash never leaves half a file
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

    /// Borders, glow, caret, solid buttons at `hue` (the live hue; see `liveHue`).
    public static func accent(_ t: Theme, _ hue: Double, alpha: Double = 1) -> RGBA { hsv(hue, t.accS, t.accV, alpha) }

    /// Small mono labels: the accent hue, paler (dimmer on Daylight), >= 4.5:1 on every hue.
    public static func labelColour(_ t: Theme, _ hue: Double, alpha: Double = 1) -> RGBA { hsv(hue, t.labS, t.labV, alpha) }

    // MARK: hues

    /// The hue the face takes in this theme. `base` is what expressions.target() gives (188 neutral, 168
    /// happy, 176 calm, 44 proud, 318 playful, 34 concerned, 216 sad, 356 error).
    ///
    /// Error is always red. Neutral poses and the two quiet moods (happy, calm) are offsets from the
    /// theme's resting hue, so Cyan reproduces today's face exactly. The signal emotions keep their own
    /// hue (proud stays gold, sad blue) but are pushed `separation` degrees away when they land that
    /// close to the resting hue (gold on Amber), so they still differ from neutral.
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

    /// Degrees from `hue` to the colour of the aura's bloom and of the border's far end: toward pink, up
    /// to `auraDh`, fading to nothing at pink and at its opposite so the face's hue sweeping past never
    /// makes it jump. Whatever the mood (an error too) it ends on a pink, magenta or violet, not on a
    /// colour of its own.
    public static func auraShift(_ t: Theme, _ hue: Double) -> Double { t.auraDh * sin((pink - hue) * (Double.pi / 180)) }

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
