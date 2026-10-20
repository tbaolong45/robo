// Tests of the one theme, Liquid Glass, and of the user's theme.json. The token validation, the hue maths and the
// accent colours are the Python module's (src/robo/theme.py); the golden numbers below come from it. The five HUD
// themes are gone from the Swift build, so their tables and the colour, contrast and aura checks went with them.
// Not ported, because Swift settles them at compile time: "importing theme pulls in no Qt and no setup"
// (RoboCore imports no AppKit) and "the revision is not a constructor argument" (`rev` is get-only).
import Foundation
import Testing
@testable import RoboCore

// MARK: helpers

/// Every token as the JSON name the config file uses, with the Swift value.
func snapshot(_ t: Theme) -> [String: Any] {
    var out: [String: Any] = [:]
    for case let (label?, value) in Mirror(reflecting: t).children where label != "revision" {
        let snake = label.reduce(into: "") { $0 += $1.isUppercase ? "_" + $1.lowercased() : String($1) }
        if let pair = value as? Theme.FaceBG { out[snake] = [pair.centre, pair.edge] } else { out[snake] = value }
    }
    return out
}

private func number(_ t: Theme, _ name: String) -> Double {
    let v = snapshot(t)[name]!
    return (v as? Double) ?? Double(v as! Int)
}

private func resolve(_ pairs: (String, PyJSON)...) -> Theme {
    Themes.resolve(.object(pairs.map { ($0.0, $0.1) }))
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

// token -> (low, high). `hue` wraps instead and is tested apart.
private let ranges: [(name: String, lo: Double, hi: Double)] = [
    ("acc_s", 0, 1), ("acc_v", 0.3, 1), ("text_px", 12, 18), ("line_h", 105, 150), ("cps", 0, 400), ("caret_ms", 300, 1000)]

@Test func glassIsTheOnlyThemeAndTheDefault() {
    let t = Theme()
    #expect(t == Themes.glass)
    #expect(t.key == "glass" && t.label == "Liquid Glass")
    #expect(t.hue == 188 && t.followEmotion && t.cps == 55)
    #expect(t.botName == "ROBO" && t.modelChip == "" && t.caret == "block")
}

@Test func theRestingHueIsTheFaces() {
    // FaceParams().hue in src/robo/face/expressions.py is 188.0 (the face is ported elsewhere)
    #expect(Themes.faceBaseHue == 188)
}

/// Every token of `t` is inside what the token table allows.
private func valid(_ t: Theme) {
    for (name, lo, hi) in ranges {
        let v = number(t, name)
        #expect(lo <= v && v <= hi, Comment(rawValue: "\(name)=\(v)"))
    }
    #expect(0 <= t.hue && t.hue < 360)
    #expect(["block", "bar", "under"].contains(t.caret))
    #expect(!pyStrip(t.botName).isEmpty && t.botName.unicodeScalars.count <= 12 && t.modelChip.unicodeScalars.count <= 12)
}

@Test func everyTokenOfGlassIsValid() {
    let t = Themes.glass
    valid(t)
    let all = PyJSON.object(ranges.map { r in
        let v = snapshot(t)[r.name]!
        return (r.name, (v as? Int).map(PyJSON.int) ?? .double(v as! Double))
    })
    #expect(Themes.resolve(all) == t)
}

// MARK: - resolve and load

@Test func noTokensIsGlass() {
    #expect(Themes.resolve(nil).rev == Themes.glass.rev)
    #expect(Themes.resolve(.string("nope")).rev == Themes.glass.rev)
    #expect(Themes.resolve(.array([.string("matrix")])).rev == Themes.glass.rev)  // a JSON list must not raise
}

@Test func noFileIsPlainGlass() {
    withConfig { cfg in #expect(Themes.load(path: cfg).rev == Themes.glass.rev) }
}

@Test func fileOverridesTokens() throws {
    try withConfig { cfg in
        try write(cfg, #"""
            {"tokens": {"bot_name": "PIXEL", "hue": 300, "cps": 80, "caret": "bar", "model_chip": "x",
             "follow_emotion": false, "face_bg": ["#101010", "#202020"], "text_px": 16, "acc_s": 0.5}}
            """#)
        let t = Themes.load(path: cfg)
        #expect(t.key == "glass" && t.botName == "PIXEL" && t.hue == 300 && t.cps == 80 && t.caret == "bar")
        #expect(t.modelChip == "x" && !t.followEmotion && t.faceBg == Theme.FaceBG("#101010", "#202020"))
        #expect(t.textPx == 16 && t.accS == 0.5)
        #expect(t.lineH == Themes.glass.lineH && t.caretMs == Themes.glass.caretMs)  // untouched tokens stay the theme's
    }
}

@Test func anOldThemeFileLoadsAsGlassWithTheTokensThatSurvive() throws {
    try withConfig { cfg in
        try write(cfg, ##"{"theme":"matrix","tokens":{"bg_top":"#000000","scan_a":0.2,"hue":120,"bot_name":"PIXEL"}}"##)
        let t = Themes.load(path: cfg)
        #expect(t.key == "glass" && t.label == "Liquid Glass" && t.hue == 120 && t.botName == "PIXEL")
        #expect(t == Themes.glass.with { $0.hue = 120; $0.botName = "PIXEL" })  // and nothing else changed
    }
}

@Test func aFileWithOnlyAThemeKeyIsPlainGlass() throws {
    try withConfig { cfg in
        try write(cfg, #"{"theme": "matrix"}"#)
        #expect(Themes.load(path: cfg).rev == Themes.glass.rev)
        try write(cfg, ##"{"theme": "amber", "tokens": {"bg_top": "#000000", "scan_a": 0.2}}"##)  // only removed tokens
        #expect(Themes.load(path: cfg).rev == Themes.glass.rev)
    }
}

@Test func aBadTokenIsSkippedAndTheRestApplies() throws {
    try withConfig { cfg in
        try write(cfg, ##"{"tokens": {"hue": "red", "cps": 90, "face_bg": ["#zzz", "#000000"], "bot_name": "PIXEL"}}"##)
        let t = Themes.load(path: cfg)
        #expect(t.hue == 188 && t.cps == 90 && t.faceBg == Themes.glass.faceBg && t.botName == "PIXEL")
    }
}

struct Hostile: Sendable, CustomTestStringConvertible {
    let name: String, content: String
    init(_ name: String, _ content: String) { (self.name, self.content) = (name, content) }
    var testDescription: String { name }
}

private let hostile: [Hostile] = [
    Hostile("every token bad",##"{"theme": "matrix", "tokens": {"hue": "red", "bg_top": "#zzz", "cps": true,"##
        + ##" "bogus": 1, "bot_name": ""## + String(repeating: "x", count: 40) + ##"", "caret": "blink", "shape": 3,"##
        + ##" "follow_emotion": "yes", "face_bg": ["#000"], "model_chip": 5, "text_px": null,"##
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
        #expect(t.key == "glass" && t.hue == 188)
        #expect(t.botName == "ROBO" && t.caret == "block")
    }
}

@Test func hostileFileValuesAreIndividuallyDropped() throws {
    try withConfig { cfg in
        try write(cfg, ##"{"theme": "matrix", "tokens": {"hue": "red", "bg_top": "#zzz", "cps": true, "bogus": 1, "bot_name": ""##
            + String(repeating: "x", count: 40) + ##""}}"##)
        let t = Themes.load(path: cfg)
        #expect(t == Themes.glass)
        #expect(snapshot(t)["bogus"] == nil)
    }
}

@Test func aByteOrderMarkMakesTheFileNotJSON() throws {
    // Python reads the file as text and json.loads refuses a leading U+FEFF: plain glass
    try withConfig { cfg in
        try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array(#"{"tokens": {"hue": 120}}"#.utf8))
        try bytes.write(to: cfg)
        #expect(Themes.load(path: cfg).rev == Themes.glass.rev)
    }
}

@Test func aBinaryFileIsNotATheme() throws {
    try withConfig { cfg in
        try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0x00, 0x80]).write(to: cfg)
        #expect(Themes.load(path: cfg).rev == Themes.glass.rev)
    }
}

@Test(arguments: ranges.map { Range3(name: $0.name, lo: $0.lo, hi: $0.hi) })
func numbersClamp(_ r: Range3) {
    let mid = (r.lo + r.hi) / 2
    let low = resolve((r.name, .double(r.lo - 1000)))
    #expect(number(low, r.name) == r.lo)
    #expect(number(resolve((r.name, .double(r.hi + 1000))), r.name) == r.hi)
    #expect(abs(number(resolve((r.name, .double(mid))), r.name) - mid) <= 0.51)
    valid(low)
}

struct Range3: Sendable, CustomTestStringConvertible {
    let name: String
    let lo: Double, hi: Double
    var testDescription: String { name }
}

@Test func hueWrapsInsteadOfClamping() {
    #expect(resolve(("hue", .int(725))).hue == 5)
    #expect(resolve(("hue", .int(-10))).hue == 350)
    #expect(resolve(("hue", .double(359.5))).hue == 359.5)
}

@Test func pythonEdgeCasesOfTokenValues() {
    // each expectation below is what theme.resolve gave in Python 3.14
    #expect(resolve(("hue", .big("1" + String(repeating: "0", count: 30)))).hue == 280)  // 10**30 % 360
    #expect(resolve(("hue", .big("-1" + String(repeating: "0", count: 30)))).hue == 80)
    #expect(resolve(("hue", .big("123456789012345678901234567890"))).hue == 90)
    #expect(resolve(("hue", .double(-1e-20))).hue == 360)  // float % rounds up to the divisor, as in Python
    #expect(resolve(("hue", .double(1e300))).hue == 0)
    #expect(resolve(("hue", .double(.infinity))).hue == 188)  // not finite: skipped
    #expect(resolve(("hue", .bool(true))).hue == 188)  // a bool is not a number
    #expect(resolve(("text_px", .double(12.5))).textPx == 12)  // round half to even
    #expect(resolve(("text_px", .double(13.5))).textPx == 14)
    #expect(resolve(("text_px", .double(14.5))).textPx == 14)
    #expect(resolve(("text_px", .double(17.5))).textPx == 18)
    #expect(resolve(("text_px", .big("1" + String(repeating: "0", count: 40)))).textPx == 18)
    #expect(resolve(("text_px", .big("-1" + String(repeating: "0", count: 40)))).textPx == 12)
    #expect(resolve(("cps", .big("1" + String(repeating: "0", count: 40)))).cps == 400)
    #expect(resolve(("cps", .double(.infinity))).cps == 55)
    #expect(resolve(("cps", .double(-1e-300))).cps == 0)
    #expect(resolve(("cps", .bool(true))).cps == 55)
}

@Test func integerTokensStayIntegers() {
    let t = resolve(("line_h", .double(120.4)), ("text_px", .double(15.2)), ("caret_ms", .double(600.0)))
    #expect(t.lineH == 120 && t.textPx == 15 && t.caretMs == 600)
    #expect(["line_h", "text_px", "caret_ms"].allSatisfy { snapshot(t)[$0] is Int })
}

@Test func nameLabelKeyAndRevCannotBeOverridden() {
    let base = Themes.glass
    let t = resolve(("label", .string("x")), ("key", .string("matrix")), ("rev", .int(0)))
    #expect(t.label == base.label && t.key == "glass")
    #expect(t.rev == base.rev)  // nothing valid: the theme itself comes back
    let other = resolve(("label", .string("x")), ("key", .string("matrix")), ("rev", .int(0)), ("hue", .int(10)))
    #expect(other.label == base.label && other.key == "glass" && other.rev != 0 && other.rev != base.rev)
}

@Test func textTokens() {
    let t = resolve(("bot_name", .string(String(repeating: "x", count: 12))), ("model_chip", .string("")))
    #expect(t.botName == String(repeating: "x", count: 12) && t.modelChip == "")
    #expect(resolve(("bot_name", .string(""))).botName == "ROBO")
    #expect(resolve(("bot_name", .string("   "))).botName == "ROBO")
    #expect(resolve(("bot_name", .string("\u{85}\u{1f}"))).botName == "ROBO")  // blank by Python's str.strip
    #expect(resolve(("bot_name", .string("\u{200b}"))).botName == "\u{200b}")  // a zero-width space is not blank
    #expect(resolve(("model_chip", .string(String(repeating: "x", count: 13)))).modelChip == "")
    #expect(resolve(("bot_name", .string(String(repeating: "é", count: 12)))).botName.unicodeScalars.count == 12)
    #expect(resolve(("bot_name", .string(String(repeating: "é", count: 13)))).botName == "ROBO")
    // 12 code points that Swift counts as one character
    #expect(resolve(("bot_name", .string("e" + String(repeating: "\u{301}", count: 12)))).botName == "ROBO")
}

@Test func faceBgIsAPairOfColours() {
    let good = resolve(("face_bg", .array([.string("#101010"), .string("#202020")])))
    #expect(good.faceBg == Theme.FaceBG("#101010", "#202020"))
    for bad: PyJSON in [.array([.string("#101010")]), .string("#101010"), .array([.string("#101010"), .string("nope")]),
                        .array([.string("#101010"), .string("#202020"), .string("#303030")])] {
        #expect(resolve(("face_bg", bad)).faceBg == Themes.glass.faceBg)
    }
}

@Test func resolveWithoutValidTokensReusesTheTheme() {
    #expect(resolve(("bogus", .int(1)), ("hue", .string("red"))).rev == Themes.glass.rev)
}

// MARK: - revision counter

@Test func everyNewThemeObjectGetsANewRevision() {
    let glass = Themes.glass
    #expect(glass.with { $0.hue = 10 }.rev != glass.rev)
    #expect(glass.with { _ in }.rev != glass.rev)
    #expect(Themes.resolve(nil).rev == glass.rev)
    #expect(glass.with { _ in } == glass)  // the revision is not part of equality
    let copy = glass  // a plain copy has the same tokens, so it keeps the revision
    #expect(copy.rev == glass.rev)
}

@Test func twoThemesBuiltFromDifferentTokensNeverShareARevision() {
    // the card chrome cache is keyed on rev: glass, and glass with each single token changed
    var themes = [Themes.glass]
    for (name, value) in [("hue", PyJSON.int(10)), ("cps", .int(90)), ("bot_name", .string("PIXEL")), ("caret", .string("bar")),
                          ("acc_s", .double(0.5)), ("follow_emotion", .bool(false)), ("face_bg", .array([.string("#000000"), .string("#ffffff")]))] {
        themes.append(resolve((name, value)))
    }
    #expect(Set(themes.map(\.rev)).count == themes.count)
    // loading the same file twice builds two themes: new revisions, same tokens
    try? withConfig { cfg in
        try write(cfg, #"{"tokens": {"hue": 300}}"#)
        let a = Themes.load(path: cfg), b = Themes.load(path: cfg)
        #expect(a == b && a.rev != b.rev)
        #expect(a.rev != Themes.glass.rev)
    }
}

// MARK: - model chip

@Test func modelChipFollowsWhatSetupConfigured() {
    #expect(Themes.chipText(Themes.glass, configuredModel: "claude-sonnet-5.5") == "sonnet-5.5")
    #expect(Themes.chipText(Themes.glass, configuredModel: "gpt-x") == "gpt-x")
    #expect(Themes.chipText(Themes.glass, configuredModel: "") == "")
}

@Test func modelChipOverrideAndHide() {
    #expect(Themes.chipText(Themes.glass.with { $0.modelChip = "hermes" }, configuredModel: "claude-x") == "hermes")
    #expect(Themes.chipText(Themes.glass.with { $0.modelChip = "  " }, configuredModel: "claude-x") == "")
    #expect(Themes.chipText(Themes.glass.with { $0.modelChip = "\u{a0}hermes\u{2003}" }, configuredModel: "") == "hermes")
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

// MARK: - hues

private let states: [(name: String, activity: String, emotion: String)] = [
    ("neutral", "idle", "neutral"), ("happy", "talking", "happy"), ("calm", "idle", "calm"), ("proud", "idle", "proud"),
    ("playful", "idle", "playful"), ("concerned", "idle", "concerned"), ("sad", "idle", "sad"), ("error", "error", "neutral")]
private let emotions = ["neutral", "happy", "curious", "proud", "concerned", "confused", "playful", "sad", "calm"]

/// expressions.target(activity, emotion).hue: an error is 356, a sleeper has no mood, and an emotion
/// brings its own hue (the others keep the face's 188). Checked against the Python table when written.
func faceHue(_ activity: String, _ emotion: String) -> Double {
    if activity == "error" { return 356 }
    if activity == "asleep" { return 188 }
    return ["happy": 168, "proud": 44, "concerned": 34, "playful": 318, "sad": 216, "calm": 176][emotion] ?? 188
}

/// Glass with another resting hue, as a theme.json {"hue": N} makes it.
private func glass(hue: Int) -> Theme { resolve(("hue", .int(hue))) }

// The face's hue per state (`states` order) for a card whose resting hue is the key: these were the hues of the
// old Cyan HUD (188), Matrix (128), Amber CRT (38), Violet Aurora (268) and Daylight (196) themes.
private let hueTable: [Int: [Double]] = [
    188: [188, 168, 176, 44, 318, 34, 216, 356],
    128: [128, 108, 116, 44, 318, 34, 216, 356],
    38: [38, 18, 26, 52, 318, 24, 216, 356],
    268: [268, 248, 256, 44, 318, 34, 216, 356],
    196: [196, 176, 184, 44, 318, 34, 216, 356]]

private func hueOf(_ t: Theme, _ s: (name: String, activity: String, emotion: String)) -> Double {
    Themes.hueFor(t, activity: s.activity, emotion: s.emotion, base: faceHue(s.activity, s.emotion))
}

@Test(arguments: [188, 128, 38, 268, 196])
func hueTableFollowsTheRestingHue(_ hue: Int) {
    let t = glass(hue: hue)
    #expect(t.hue == Double(hue))
    #expect(states.map { hueOf(t, $0) } == hueTable[hue]!)
}

@Test func faceHueIsTheFacesHueTable() {
    // expressions.target(a, e).hue for a in idle/talking/thinking, from Python
    let idle: [String: Double] = ["neutral": 188, "happy": 168, "curious": 188, "proud": 44, "concerned": 34,
                                  "confused": 188, "playful": 318, "sad": 216, "calm": 176]
    #expect(emotions.allSatisfy { faceHue("idle", $0) == idle[$0] && faceHue("talking", $0) == idle[$0] })
    #expect(emotions.allSatisfy { faceHue("error", $0) == 356 && faceHue("asleep", $0) == 188 })
}

@Test func glassReproducesTodaysFaceHuesExactly() {
    for (activity, emotion) in [("idle", "neutral"), ("talking", "happy"), ("idle", "calm"), ("idle", "proud"),
                                ("idle", "curious"), ("error", "neutral"), ("asleep", "happy"), ("thinking", "sad")] {
        let base = faceHue(activity, emotion)
        #expect(Themes.hueFor(Themes.glass, activity: activity, emotion: emotion, base: base) == base, Comment(rawValue: "\(activity) \(emotion)"))
    }
}

@Test func errorIsRedWhateverTheHueOrEmotion() {
    for hue in [188, 128, 38, 268, 196] {
        let t = glass(hue: hue)
        for emotion in emotions {
            #expect(Themes.hueFor(t, activity: "error", emotion: emotion, base: faceHue("error", emotion)) == 356)
        }
        #expect(Themes.hueFor(t, activity: "idle", emotion: "x", base: 356) == 356)
    }
}

@Test func signalHuesKeep14DegreesFromTheRestingHue() {
    for h in stride(from: 0, to: 360, by: 5) {
        let t = Themes.glass.with { $0.hue = Double(h) }
        for name in ["proud", "playful", "concerned", "sad"] {
            let s = states.first { $0.name == name }!
            #expect(abs(pyFloatMod(hueOf(t, s) - t.hue + 180, 360) - 180) >= 14 - 1e-9, Comment(rawValue: "\(h) \(name)"))
        }
    }
}

@Test func liveHueRule() {
    let amber = glass(hue: 38)
    #expect(Themes.liveHue(amber, faceNow: 17, activity: "idle") == 17)  // follows the face
    let still = amber.with { $0.followEmotion = false }
    #expect(Themes.liveHue(still, faceNow: 17, activity: "idle") == 38)  // one colour
    #expect(Themes.liveHue(still, faceNow: 356, activity: "error") == 356)  // an error always turns it red
    #expect(Themes.liveHue(amber, faceNow: 365, activity: "idle") == 5)
    #expect(Themes.liveHue(amber, faceNow: -1e-20, activity: "idle") == 360)  // Python's float %
}

// MARK: - accent colours

private func rgb8(_ c: RGBA) -> [Int] { [Int(c.r), Int(c.g), Int(c.b), Int(c.a)] }

@Test func accentColours() {
    let glass = Themes.glass
    #expect(Themes.accent(glass, 188, alpha: 1.0) == RGBA(r: 38, g: 226, b: 255, a: 255))  // HSV(188, .85, 1.0)
    #expect(Themes.accent(glass, 188, alpha: 0.5).a == 128)  // 127.5 rounds to the even 128, like Python's round
    #expect(Themes.accent(glass, 548) == Themes.accent(glass, 188))  // the hue wraps
    #expect(Themes.accent(glass, 0, alpha: 7).a == 255 && Themes.accent(glass, 0, alpha: -1).a == 0)
    #expect(Themes.accent(glass, -1e-20) == RGBA(r: 255, g: 38, b: 38, a: 255) && Themes.accent(glass, 1e300) == Themes.accent(glass, 0))
    #expect(Themes.accent(glass, 0.1, alpha: 0.9999) == RGBA(r: 255, g: 39, b: 38, a: 255))
}

@Test func accentMathsMatchesPython() {
    // theme.accent(hue, alpha) with the default accent (acc_s 0.85, acc_v 1.0), straight from Python
    let samples: [(Double, Double)] = [(0, 1), (45.5, 1), (128, 1), (188, 1), (268, 0.5), (300.25, 0.1), (356, 1), (-30, 0.333), (725, 1)]
    let expected = [[255, 38, 38, 255], [255, 203, 38, 255], [38, 255, 67, 255], [38, 226, 255, 255], [139, 38, 255, 128],
                    [255, 38, 254, 26], [255, 38, 53, 255], [255, 38, 147, 85], [255, 56, 38, 255]]
    for (i, (hue, alpha)) in samples.enumerated() {
        #expect(rgb8(Themes.accent(Themes.glass, hue, alpha: alpha)) == expected[i], Comment(rawValue: "accent \(hue)"))
    }
}

@Test func aHueOrAlphaThatIsNotANumberDrawsInsteadOfTrapping() {
    // Python raises ValueError here; the face's hue is never NaN, but a bad number must not take the app down
    let glass = Themes.glass
    for bad in [Double.nan, .infinity, -.infinity] {
        #expect(Themes.accent(glass, bad) == Themes.accent(glass, 0))
    }
    #expect(Themes.accent(glass, 188, alpha: .nan) == Themes.accent(glass, 188))
    #expect(Themes.accent(glass, 188, alpha: .infinity).a == 255 && Themes.accent(glass, 188, alpha: -.infinity).a == 0)
}

@Test func rgba() {
    #expect(Themes.rgba("#04121a") == RGBA(r: 4, g: 18, b: 26, a: 255))
    #expect(Themes.rgba("#FFFFFF", alpha: 0.5) == RGBA(r: 255, g: 255, b: 255, a: 128))
}
