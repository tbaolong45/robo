// Tests of the one theme, Liquid Glass, and of the user's theme.json.
import Foundation
import Testing
@testable import RoboCore

// MARK: helpers

/// Every token as the JSON name the config file uses, with the Swift value.
func snapshot(_ t: Theme) -> [String: Any] {
    var out: [String: Any] = [:]
    for case let (label?, value) in Mirror(reflecting: t).children {
        let snake = label.reduce(into: "") { $0 += $1.isUppercase ? "_" + $1.lowercased() : String($1) }
        if let pair = value as? Theme.FaceBG { out[snake] = [pair.centre, pair.edge] } else { out[snake] = value }
    }
    return out
}

private func number(_ t: Theme, _ name: String) -> Double {
    let v = snapshot(t)[name]!
    return (v as? Double) ?? Double(v as! Int)
}

private func resolve(_ pairs: (String, Any)...) -> Theme {
    Themes.resolve(Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1) }))
}

/// A config path inside a fresh temp folder that does not exist yet; the folder is removed afterwards.
private func withConfig(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-theme-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir.appendingPathComponent("robo/theme.json"))
}

private func write(_ path: URL, _ content: String) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: path)
}

// MARK: - the table

// token -> (low, high).
private let ranges: [(name: String, lo: Double, hi: Double)] = [
    ("text_px", 12, 18), ("line_h", 105, 150), ("cps", 0, 400), ("caret_ms", 300, 1000)]

@Test func glassIsTheOnlyThemeAndTheDefault() {
    let t = Theme()
    #expect(t == Themes.glass)
    #expect(t.key == "glass" && t.label == "Liquid Glass")
    #expect(t.cps == 55 && t.botName == "Robo" && t.caret == "block")
}

/// Every token of `t` is inside what the token table allows.
private func valid(_ t: Theme) {
    for (name, lo, hi) in ranges {
        let v = number(t, name)
        #expect(lo <= v && v <= hi, Comment(rawValue: "\(name)=\(v)"))
    }
    #expect(["block", "bar", "under"].contains(t.caret))
    #expect(t.botName.unicodeScalars.contains { !$0.isSpace } && t.botName.unicodeScalars.count <= 12)
}

@Test func everyTokenOfGlassIsValid() {
    let t = Themes.glass
    valid(t)
    #expect(Themes.resolve(Dictionary(uniqueKeysWithValues: ranges.map { ($0.name, snapshot(t)[$0.name]!) })) == t)
}

// MARK: - resolve and load

@Test func noTokensIsGlass() {
    #expect(Themes.resolve(nil) == Themes.glass)
    #expect(Themes.resolve("nope") == Themes.glass)
    #expect(Themes.resolve(["matrix"]) == Themes.glass)  // a JSON list must not raise
}

@Test func noFileIsPlainGlass() {
    withConfig { cfg in #expect(Themes.load(path: cfg) == Themes.glass) }
}

@Test func fileOverridesTokens() throws {
    try withConfig { cfg in
        try write(cfg, #"""
            {"tokens": {"bot_name": "PIXEL", "cps": 80, "caret": "bar",
             "face_bg": ["#101010", "#202020"], "text_px": 16}}
            """#)
        let t = Themes.load(path: cfg)
        #expect(t.key == "glass" && t.botName == "PIXEL" && t.cps == 80 && t.caret == "bar")
        #expect(t.faceBg == Theme.FaceBG("#101010", "#202020") && t.textPx == 16)
        #expect(t.lineH == Themes.glass.lineH && t.caretMs == Themes.glass.caretMs)  // untouched tokens stay the theme's
    }
}

@Test func anOldThemeFileLoadsAsGlassWithTheTokensThatSurvive() throws {
    try withConfig { cfg in
        try write(cfg, ##"{"theme":"matrix","tokens":{"bg_top":"#000000","scan_a":0.2,"hue":120,"acc_s":0.5,"model_chip":"x","follow_emotion":false,"bot_name":"PIXEL"}}"##)
        let t = Themes.load(path: cfg)
        #expect(t.key == "glass" && t.label == "Liquid Glass" && t.botName == "PIXEL")
        #expect(t == Themes.glass.with { $0.botName = "PIXEL" })  // and nothing else changed
    }
}

@Test func aFileWithOnlyAThemeKeyIsPlainGlass() throws {
    try withConfig { cfg in
        try write(cfg, #"{"theme": "matrix"}"#)
        #expect(Themes.load(path: cfg) == Themes.glass)
        try write(cfg, ##"{"theme": "amber", "tokens": {"bg_top": "#000000", "scan_a": 0.2}}"##)  // only removed tokens
        #expect(Themes.load(path: cfg) == Themes.glass)
    }
}

@Test func aBadTokenIsSkippedAndTheRestApplies() throws {
    try withConfig { cfg in
        try write(cfg, ##"{"tokens": {"text_px": "big", "cps": 90, "face_bg": ["#zzz", "#000000"], "bot_name": "PIXEL"}}"##)
        let t = Themes.load(path: cfg)
        #expect(t.textPx == Themes.glass.textPx && t.cps == 90 && t.faceBg == Themes.glass.faceBg && t.botName == "PIXEL")
    }
}

struct Hostile: Sendable, CustomTestStringConvertible {
    let name: String, content: String
    init(_ name: String, _ content: String) { (self.name, self.content) = (name, content) }
    var testDescription: String { name }
}

private let hostile: [Hostile] = [
    Hostile("every token bad",##"{"theme": "matrix", "tokens": {"bg_top": "#zzz", "cps": true,"##
        + ##" "bogus": 1, "bot_name": ""## + String(repeating: "x", count: 40) + ##"", "caret": "blink", "shape": 3,"##
        + ##" "face_bg": ["#000"], "text_px": null,"##
        + ##" "scan_a": [0.1], "glow": {"a": 1}, "aura": NaN, "br_len": Infinity, "radius": -Infinity,"##
        + ##" "line_h": 1"## + String(repeating: "0", count: 400) + "}}"),
    Hostile("theme is a list", #"{"theme": ["matrix"], "tokens": ["hue", 5]}"#),
    Hostile("theme is a number", #"{"theme": 5, "tokens": "hue"}"#),
    Hostile("tokens is null", #"{"theme": "matrix", "tokens": null}"#),
    Hostile("list", "[1, 2, 3]"),
    Hostile("string", #""matrix""#),
    Hostile("null", "null"),
    Hostile("number", "42"),
    Hostile("true", "true"),
    Hostile("empty", ""),
    Hostile("not json", "{not json"),
    Hostile("nested too deep", String(repeating: "[", count: 200_000)),
]

@Test(arguments: hostile)
func hostileFileStillGivesAValidTheme(_ h: Hostile) throws {
    try withConfig { cfg in
        try write(cfg, h.content)
        let t = Themes.load(path: cfg)
        valid(t)
        #expect(t.key == "glass" && t.botName == "Robo" && t.caret == "block")
    }
}

@Test func hostileFileValuesAreIndividuallyDropped() throws {
    try withConfig { cfg in
        try write(cfg, ##"{"theme": "matrix", "tokens": {"bg_top": "#zzz", "cps": true, "bogus": 1, "bot_name": ""##
            + String(repeating: "x", count: 40) + ##""}}"##)
        let t = Themes.load(path: cfg)
        #expect(t == Themes.glass)
        #expect(snapshot(t)["bogus"] == nil)
    }
}

@Test func aBinaryFileIsNotATheme() throws {
    try withConfig { cfg in
        try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0x00, 0x80]).write(to: cfg)
        #expect(Themes.load(path: cfg) == Themes.glass)
    }
}

@Test(arguments: ranges.map { Range3(name: $0.name, lo: $0.lo, hi: $0.hi) })
func numbersClamp(_ r: Range3) {
    let mid = (r.lo + r.hi) / 2
    let low = resolve((r.name, r.lo - 1000))
    #expect(number(low, r.name) == r.lo)
    #expect(number(resolve((r.name, r.hi + 1000)), r.name) == r.hi)
    #expect(abs(number(resolve((r.name, mid)), r.name) - mid) <= 0.51)
    valid(low)
}

struct Range3: Sendable, CustomTestStringConvertible {
    let name: String
    let lo: Double, hi: Double
    var testDescription: String { name }
}

@Test func edgeCasesOfTokenValues() {
    #expect(resolve(("text_px", 12.5)).textPx == 13)
    #expect(resolve(("text_px", 13.4)).textPx == 13)
    #expect(resolve(("text_px", 1e40)).textPx == 18)
    #expect(resolve(("text_px", -1e40)).textPx == 12)
    #expect(resolve(("cps", 1e40)).cps == 400)
    #expect(resolve(("cps", Double.infinity)).cps == 55)
    #expect(resolve(("cps", -1e-300)).cps == 0)
    #expect(resolve(("cps", true)).cps == 55)
}

@Test func integerTokensStayIntegers() {
    let t = resolve(("line_h", 120.4), ("text_px", 15.2), ("caret_ms", 600.0))
    #expect(t.lineH == 120 && t.textPx == 15 && t.caretMs == 600)
    #expect(["line_h", "text_px", "caret_ms"].allSatisfy { snapshot(t)[$0] is Int })
}

@Test func nameLabelAndKeyCannotBeOverridden() {
    let base = Themes.glass
    let t = resolve(("label", "x"), ("key", "matrix"))
    #expect(t.label == base.label && t.key == "glass")
    #expect(t == base)  // nothing valid: the theme itself comes back
    let other = resolve(("label", "x"), ("key", "matrix"), ("cps", 10))
    #expect(other.label == base.label && other.key == "glass" && other.cps == 10)
}

@Test func textTokens() {
    #expect(resolve(("bot_name", String(repeating: "x", count: 12))).botName == String(repeating: "x", count: 12))
    #expect(resolve(("bot_name", String(repeating: "x", count: 13))).botName == "Robo")
    for blank in ["", "   ", "\u{85}\u{1f}", "\u{200b}"] {  // spaces, controls and a zero-width space show nothing
        #expect(resolve(("bot_name", blank)).botName == "Robo", Comment(rawValue: blank.debugDescription))
    }
    #expect(resolve(("bot_name", 5)).botName == "Robo")
}

@Test func faceBgIsAPairOfColours() {
    #expect(resolve(("face_bg", ["#101010", "#202020"])).faceBg == Theme.FaceBG("#101010", "#202020"))
    for bad: Any in [["#101010"], "#101010", ["#101010", "nope"], ["#101010", "#202020", "#303030"]] {
        #expect(resolve(("face_bg", bad)).faceBg == Themes.glass.faceBg)
    }
}

@Test func resolveWithoutValidTokensReusesTheTheme() {
    #expect(resolve(("bogus", 1), ("cps", "fast")) == Themes.glass)
}

// MARK: - the file's stamp and path

@Test func stampChangesWhenTheFileDoes() throws {
    try withConfig { cfg in
        #expect(Themes.stamp(path: cfg) == 0)
        try write(cfg, "{}")
        let first = Themes.stamp(path: cfg)
        #expect(first > 0)
        let moved = timespec(tv_sec: first / 1_000_000_000 + 1, tv_nsec: first % 1_000_000_000)
        var times = [moved, moved]
        utimensat(AT_FDCWD, cfg.path, &times, 0)
        #expect(Themes.stamp(path: cfg) == first + 1_000_000_000)
    }
}

@Test func configPathFollowsXDG() {
    #expect(Themes.configPath(environment: ["XDG_CONFIG_HOME": "/x/xdg", "HOME": "/x/home"]).path == "/x/xdg/robo/theme.json")
    #expect(Themes.configPath(environment: ["XDG_CONFIG_HOME": "", "HOME": "/x/home"]).path == "/x/home/.config/robo/theme.json")
    #expect(Themes.configPath(environment: ["HOME": "/x/home"]).path == "/x/home/.config/robo/theme.json")
}

@Test func rgba() {
    #expect(Themes.rgba("#04121a") == RGBA(r: 4, g: 18, b: 26, a: 255))
    #expect(Themes.rgba("#FFFFFF", alpha: 0.5) == RGBA(r: 255, g: 255, b: 255, a: 128))
}
