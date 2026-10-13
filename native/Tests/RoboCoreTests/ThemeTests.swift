// Port of tests/test_theme.py, plus golden checks against values computed by the Python module
// (the theme tables, the colour maths, the edge cases of token resolution).
// Not ported, because Swift settles them at compile time: "importing theme pulls in no Qt and no setup"
// (RoboCore imports no AppKit) and "the revision is not a constructor argument" (`rev` is get-only).
import Foundation
import Testing
@testable import RoboCore

private let keys = ["cyan", "matrix", "amber", "aurora", "daylight"]

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

private func colour(_ t: Theme, _ name: String) -> String { snapshot(t)[name] as! String }

/// Does the Swift value equal what Python's `asdict` gave (an int and a float of the same size are equal)?
private func matches(_ swift: Any, _ py: PyJSON) -> Bool {
    switch py {
    case .bool(let b): return swift as? Bool == b
    case .int(let n): return (swift as? Double) == Double(n) || (swift as? Int) == n
    case .double(let d): return (swift as? Double) == d
    case .string(let s): return (swift as? String) == s
    case .array(let items): return (swift as? [String]).map { $0.count == items.count && zip($0, items).allSatisfy { matches($0, $1) } } ?? false
    default: return false
    }
}

private func differences(_ t: Theme, _ golden: PyJSON) -> [String] {
    guard case .object(let pairs) = golden else { return ["golden is not an object"] }
    let mine = snapshot(t)
    var bad = pairs.filter { pair in !(mine[pair.key].map { matches($0, pair.value) } ?? false) }.map(\.key)
    if mine.count != pairs.count { bad.append("token count \(mine.count) vs \(pairs.count)") }
    return bad
}

private func resolve(_ key: String, _ pairs: (String, PyJSON)...) -> Theme {
    Themes.resolve(.string(key), .object(pairs.map { ($0.0, $0.1) }))
}

/// A config path inside a fresh temp folder that does not exist yet; the folder is removed afterwards.
private func withConfig(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-theme-\(UUID().uuidString)")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.appendingPathComponent("robo").path)
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir.appendingPathComponent("robo/theme.json"))
}

private func write(_ path: URL, _ content: String) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: path)
}

private func text(_ path: URL) -> String { String(decoding: try! Data(contentsOf: path), as: UTF8.self) }

private func files(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

// MARK: - the table

// Spec 3.4: token -> (low, high). `hue` wraps instead and is tested apart.
private let ranges: [(name: String, lo: Double, hi: Double)] = [
    ("acc_s", 0, 1), ("lab_s", 0, 1), ("lab_v", 0, 1), ("grid_a", 0, 1), ("acc_v", 0.3, 1), ("bg_a", 0.90, 1),
    ("sheen", 0, 0.6), ("scan_a", 0, 0.4), ("scan_px", 2, 8), ("aura", 0, 0.3), ("aura_dh", 0, 120),
    ("corner", 0, 24), ("border_a", 0.2, 1), ("glow", 0, 1.6), ("br_len", 0, 30), ("br_w", 0.8, 3),
    ("radius", 0, 12), ("text_px", 12, 18), ("line_h", 105, 150), ("cps", 0, 400), ("caret_ms", 300, 1000)]
private let colours = ["bg_top", "bg_bot", "scan_c", "text", "text_dim", "head", "link", "code_bg", "code_fg",
                       "inline_bg", "on_accent", "led_ok", "led_warn", "led_bad"]

@Test func fiveThemesInMenuOrder() {
    #expect(Themes.all.map(\.key) == keys)
    #expect(Themes.all.map(\.label) == ["Cyan HUD", "Matrix", "Amber CRT", "Violet Aurora", "Daylight"])
}

@Test func cyanIsTheDefault() {
    let t = Theme()
    #expect(t == Themes.cyan)
    #expect(t.hue == 188 && t.cps == 55 && t.botName == "ROBO" && t.modelChip == "" && t.caret == "block")
    #expect(t.shape == "cut" && t.corner == 9 && t.dark)
}

@Test func everyThemeFollowsTheFaceMood() {
    // The user's decision: the card accent follows the live emotion hue in all five themes.
    #expect(Themes.all.allSatisfy { $0.followEmotion })
}

struct Spec: Sendable, CustomTestStringConvertible {
    let key: String
    let hue: Double, cps: Double
    let shape: String
    let corner: Int, caretMs: Int
    let dark: Bool
    let text: String, bgTop: String
    var testDescription: String { key }
}

@Test(arguments: [
    Spec(key: "cyan", hue: 188, cps: 55, shape: "cut", corner: 9, caretMs: 530, dark: true, text: "#e6efff", bgTop: "#0b1322"),
    Spec(key: "matrix", hue: 128, cps: 70, shape: "cut", corner: 0, caretMs: 530, dark: true, text: "#c9f6d3", bgTop: "#04100a"),
    Spec(key: "amber", hue: 38, cps: 40, shape: "round", corner: 14, caretMs: 620, dark: true, text: "#ffdca8", bgTop: "#150d05"),
    Spec(key: "aurora", hue: 268, cps: 50, shape: "round", corner: 16, caretMs: 530, dark: true, text: "#efe8ff", bgTop: "#150d2a"),
    Spec(key: "daylight", hue: 196, cps: 55, shape: "round", corner: 12, caretMs: 530, dark: false, text: "#13223a", bgTop: "#f7fbff"),
])
func specValues(_ s: Spec) {
    let t = Themes.all.first { $0.key == s.key }!
    #expect(t.hue == s.hue && t.cps == s.cps && t.shape == s.shape && t.corner == s.corner)
    #expect(t.caretMs == s.caretMs && t.dark == s.dark && t.text == s.text && t.bgTop == s.bgTop)
}

@Test func monoThemesSetTheBodyInMono() {
    #expect(Set(Themes.all.filter(\.bodyMono).map(\.key)) == ["matrix", "amber"])
    #expect(Themes.cyan.textPx == 14 && Themes.matrix.textPx == 13)
}

@Test func theRestingHueIsTheFaces() {
    // FaceParams().hue in src/robo/face/expressions.py is 188.0 (the face is ported elsewhere)
    #expect(Themes.faceBaseHue == 188)
}

/// Every token of `t` is inside what spec 3.4 allows.
private func valid(_ t: Theme) {
    for (name, lo, hi) in ranges {
        let v = number(t, name)
        #expect(lo <= v && v <= hi, Comment(rawValue: "\(name)=\(v)"))
    }
    #expect(0 <= t.hue && t.hue < 360)
    for name in colours {
        let c = Array(colour(t, name).unicodeScalars)
        #expect(c.count == 7 && c[0] == "#" && UInt32(String(String.UnicodeScalarView(c[1...])), radix: 16) != nil, Comment(rawValue: name))
    }
    #expect(["cut", "round"].contains(t.shape) && ["block", "bar", "under"].contains(t.caret))
    #expect(!pyStrip(t.botName).isEmpty && t.botName.unicodeScalars.count <= 12 && t.modelChip.unicodeScalars.count <= 12)
}

@Test func everyTokenOfEveryThemeIsValid() {
    for t in Themes.all {
        valid(t)
        let all = PyJSON.object(ranges.map { r in
            let v = snapshot(t)[r.name]!
            return (r.name, (v as? Int).map(PyJSON.int) ?? .double(v as! Double))
        })
        #expect(Themes.resolve(.string(t.key), all) == t, Comment(rawValue: t.key))
    }
}

@Test func swiftTablesAreThePythonTables() throws {
    // theme.THEMES through dataclasses.asdict, minus rev (Python 3 .14 run, 2026-10-13)
    let golden = try PyJSON.parse(pythonThemes)
    guard case .object(let pairs) = golden else { return }
    #expect(pairs.map(\.key) == keys)
    for (key, fields) in pairs {
        let t = Themes.all.first { $0.key == key }!
        #expect(differences(t, fields).isEmpty, Comment(rawValue: "\(key): \(differences(t, fields))"))
    }
}

// MARK: - resolve and load

@Test func unknownThemeIsCyan() {
    #expect(Themes.resolve(.string("nope"), nil).rev == Themes.cyan.rev)
    #expect(Themes.resolve(nil, nil).rev == Themes.cyan.rev)
    #expect(Themes.resolve(.array([.string("matrix")]), nil).rev == Themes.cyan.rev)  // a JSON list must not raise
}

@Test func noFileIsPlainCyan() {
    withConfig { cfg in #expect(Themes.load(path: cfg).rev == Themes.cyan.rev) }
}

@Test func filePicksAThemeAndOverridesTokens() throws {
    try withConfig { cfg in
        try write(cfg, #"""
            {"theme": "matrix", "tokens": {"bot_name": "PIXEL", "hue": 300, "cps": 80, "caret": "bar",
             "scan_a": 0, "model_chip": "x", "text": "#ABCDEF"}}
            """#)
        let t = Themes.load(path: cfg)
        #expect(t.key == "matrix" && t.botName == "PIXEL" && t.hue == 300 && t.cps == 80 && t.caret == "bar")
        #expect(t.scanA == 0 && t.modelChip == "x" && t.text == "#ABCDEF")
        #expect(t.corner == Themes.matrix.corner)  // untouched tokens stay the theme's
        #expect(Themes.load(path: cfg, choice: "daylight").key == "daylight")
        #expect(Themes.load(path: cfg, choice: "daylight").botName == "PIXEL")  // a menu pick keeps the overrides
    }
}

@Test func aBadTokenIsSkippedAndTheRestApplies() throws {
    try withConfig { cfg in
        try write(cfg, ##"{"tokens": {"hue": "red", "cps": 90, "bg_top": "#zzz", "bot_name": "PIXEL"}}"##)
        let t = Themes.load(path: cfg)
        #expect(t.hue == 188 && t.cps == 90 && t.bgTop == "#0b1322" && t.botName == "PIXEL")
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
        #expect(t.hue == 188 || t.hue == 128)  // cyan, or matrix when the file named it
        #expect(t.botName == "ROBO" && t.caret == "block")
    }
}

@Test func hostileFileValuesAreIndividuallyDropped() throws {
    try withConfig { cfg in
        try write(cfg, ##"{"theme": "matrix", "tokens": {"hue": "red", "bg_top": "#zzz", "cps": true, "bogus": 1, "bot_name": ""##
            + String(repeating: "x", count: 40) + ##""}}"##)
        let t = Themes.load(path: cfg)
        #expect(t.hue == 128 && t.bgTop == "#04100a" && t.cps == 70 && t.botName == "ROBO")
        #expect(snapshot(t)["bogus"] == nil)
    }
}

@Test func aByteOrderMarkMakesTheFileNotJSON() throws {
    // Python reads the file as text and json.loads refuses a leading U+FEFF: cyan, and a pick is never saved over it
    try withConfig { cfg in
        try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array(#"{"theme": "matrix"}"#.utf8))
        try bytes.write(to: cfg)
        #expect(Themes.load(path: cfg).rev == Themes.cyan.rev)
        #expect(Themes.saveChoice("amber", path: cfg) == false)
        #expect(try Data(contentsOf: cfg) == bytes)
    }
}

@Test func aBinaryFileIsNotATheme() throws {
    try withConfig { cfg in
        try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0x00, 0x80]).write(to: cfg)
        #expect(Themes.load(path: cfg).rev == Themes.cyan.rev)
    }
}

@Test(arguments: ranges.map { Range3(name: $0.name, lo: $0.lo, hi: $0.hi) })
func numbersClamp(_ r: Range3) {
    let mid = (r.lo + r.hi) / 2
    let low = resolve("cyan", (r.name, .double(r.lo - 1000)))
    #expect(number(low, r.name) == r.lo)
    #expect(number(resolve("cyan", (r.name, .double(r.hi + 1000))), r.name) == r.hi)
    #expect(abs(number(resolve("cyan", (r.name, .double(mid))), r.name) - mid) <= 0.51)
    valid(low)
}

struct Range3: Sendable, CustomTestStringConvertible {
    let name: String
    let lo: Double, hi: Double
    var testDescription: String { name }
}

@Test func hueWrapsInsteadOfClamping() {
    #expect(resolve("cyan", ("hue", .int(725))).hue == 5)
    #expect(resolve("cyan", ("hue", .int(-10))).hue == 350)
    #expect(resolve("cyan", ("hue", .double(359.5))).hue == 359.5)
}

@Test func pythonEdgeCasesOfTokenValues() {
    // each expectation below is what theme.resolve gave in Python 3.14
    #expect(resolve("cyan", ("hue", .big("1" + String(repeating: "0", count: 30)))).hue == 280)  // 10**30 % 360
    #expect(resolve("cyan", ("hue", .big("-1" + String(repeating: "0", count: 30)))).hue == 80)
    #expect(resolve("cyan", ("hue", .big("123456789012345678901234567890"))).hue == 90)
    #expect(resolve("cyan", ("hue", .double(-1e-20))).hue == 360)  // float % rounds up to the divisor, as in Python
    #expect(resolve("cyan", ("hue", .double(1e300))).hue == 0)
    #expect(resolve("cyan", ("hue", .double(.infinity))).hue == 188)  // not finite: skipped
    #expect(resolve("cyan", ("scan_px", .double(2.5))).scanPx == 2)  // round half to even
    #expect(resolve("cyan", ("scan_px", .double(3.5))).scanPx == 4)
    #expect(resolve("cyan", ("scan_px", .double(4.5))).scanPx == 4)
    #expect(resolve("cyan", ("scan_px", .double(7.5))).scanPx == 8)
    #expect(resolve("cyan", ("scan_px", .big("1" + String(repeating: "0", count: 40)))).scanPx == 8)
    #expect(resolve("cyan", ("scan_px", .big("-1" + String(repeating: "0", count: 40)))).scanPx == 2)
    #expect(resolve("cyan", ("cps", .big("1" + String(repeating: "0", count: 40)))).cps == 400)
    #expect(resolve("cyan", ("cps", .double(.infinity))).cps == 55)
    #expect(resolve("cyan", ("cps", .double(-1e-300))).cps == 0)
}

@Test func integerTokensStayIntegers() {
    let t = resolve("cyan", ("scan_px", .double(3.7)), ("text_px", .double(15.2)), ("caret_ms", .double(600.0)))
    #expect(t.scanPx == 4 && t.textPx == 15 && t.caretMs == 600)
    #expect(["scan_px", "text_px", "caret_ms"].allSatisfy { snapshot(t)[$0] is Int })
}

@Test func nameLabelDarkKeyAndRevCannotBeOverridden() {
    let base = Themes.daylight
    let t = resolve("daylight", ("label", .string("x")), ("dark", .bool(true)), ("key", .string("cyan")), ("rev", .int(0)))
    #expect(t.label == base.label && t.dark == false && t.key == "daylight")
    #expect(t.rev == base.rev)  // nothing valid: the theme itself comes back
    let other = resolve("daylight", ("label", .string("x")), ("rev", .int(0)), ("hue", .int(10)))
    #expect(other.label == base.label && other.key == "daylight" && other.rev != 0 && other.rev != base.rev)
}

@Test func textTokens() {
    let t = resolve("cyan", ("bot_name", .string(String(repeating: "x", count: 12))), ("model_chip", .string("")))
    #expect(t.botName == String(repeating: "x", count: 12) && t.modelChip == "")
    #expect(resolve("cyan", ("bot_name", .string(""))).botName == "ROBO")
    #expect(resolve("cyan", ("bot_name", .string("   "))).botName == "ROBO")
    #expect(resolve("cyan", ("bot_name", .string("\u{85}\u{1f}"))).botName == "ROBO")  // blank by Python's str.strip
    #expect(resolve("cyan", ("bot_name", .string("\u{200b}"))).botName == "\u{200b}")  // a zero-width space is not blank
    #expect(resolve("cyan", ("model_chip", .string(String(repeating: "x", count: 13)))).modelChip == "")
    #expect(resolve("cyan", ("bot_name", .string(String(repeating: "é", count: 12)))).botName.unicodeScalars.count == 12)
    #expect(resolve("cyan", ("bot_name", .string(String(repeating: "é", count: 13)))).botName == "ROBO")
    // 12 code points that Swift counts as one character
    #expect(resolve("cyan", ("bot_name", .string("e" + String(repeating: "\u{301}", count: 12)))).botName == "ROBO")
}

@Test func coloursMustBeSixDigitHex() {
    for bad: PyJSON in [.string("#abc"), .string("#zzzzzz"), .string("red"), .string("rgb(1,2,3)"), .string("#12345678"), .int(0x123456), .null] {
        #expect(resolve("cyan", ("text", bad)).text == Themes.cyan.text)
    }
    #expect(resolve("cyan", ("text", .string("#AbCdEf"))).text == "#AbCdEf")
}

@Test func faceBgIsAPairOfColours() {
    let good = resolve("cyan", ("face_bg", .array([.string("#101010"), .string("#202020")])))
    #expect(good.faceBg == Theme.FaceBG("#101010", "#202020"))
    for bad: PyJSON in [.array([.string("#101010")]), .string("#101010"), .array([.string("#101010"), .string("nope")]),
                        .array([.string("#101010"), .string("#202020"), .string("#303030")])] {
        #expect(resolve("cyan", ("face_bg", bad)).faceBg == Themes.cyan.faceBg)
    }
}

@Test func resolveWithoutValidTokensReusesTheTheme() {
    #expect(resolve("matrix", ("bogus", .int(1)), ("hue", .string("red"))).rev == Themes.matrix.rev)
}

@Test func tokenResolutionMatchesPythonOnThePickedCases() throws {
    // theme.resolve(key, tokens) in Python, as asdict; the full 6000-case comparison is not embedded
    let cases: [(String, String, [String: String])] = [
        ("matrix", #"{"hue": 725, "cps": 80, "caret": "bar", "bogus": 1}"#, ["hue": "5.0", "cps": "80.0", "caret": "bar"]),
        ("amber", ##"{"face_bg": ["#101010", "#202020"], "follow_emotion": false, "glow": 9}"##, ["glow": "1.6", "follow_emotion": "False"]),
        ("daylight", ##"{"acc_v": 0.1, "scan_px": 2.5, "bot_name": "  ", "model_chip": "  "}"##, ["acc_v": "0.3", "scan_px": "2", "bot_name": "ROBO", "model_chip": "  "]),
    ]
    for (key, json, expect) in cases {
        let t = Themes.resolve(.string(key), try PyJSON.parse(json))
        for (name, repr) in expect {
            let v = snapshot(t)[name]!
            let shown: String = (v as? Double).map { pyFloatRepr($0) } ?? (v as? Bool).map { $0 ? "True" : "False" } ?? "\(v)"
            #expect(shown == repr, Comment(rawValue: "\(key).\(name)"))
        }
    }
}

// MARK: - revision counter

@Test func everyNewThemeObjectGetsANewRevision() {
    let cyan = Themes.cyan
    #expect(cyan.with { $0.hue = 10 }.rev != cyan.rev)
    #expect(cyan.with { _ in }.rev != cyan.rev)
    #expect(Themes.resolve(.string("cyan"), nil).rev == cyan.rev)
    #expect(Set(Themes.all.map(\.rev)).count == Themes.all.count)
    #expect(cyan.with { _ in } == cyan)  // the revision is not part of equality
    let copy = cyan  // a plain copy has the same tokens, so it keeps the revision
    #expect(copy.rev == cyan.rev)
}

@Test func twoThemesBuiltFromDifferentTokensNeverShareARevision() {
    // the card chrome cache is keyed on rev: the five presets, and every one of them with each single token changed
    var themes = Themes.all
    for key in keys {
        for (name, value) in [("hue", PyJSON.int(10)), ("cps", .int(90)), ("bot_name", .string("PIXEL")), ("caret", .string("bar")),
                              ("text", .string("#123456")), ("follow_emotion", .bool(false)), ("face_bg", .array([.string("#000000"), .string("#ffffff")]))] {
            themes.append(resolve(key, (name, value)))
        }
    }
    #expect(Set(themes.map(\.rev)).count == themes.count)
    // loading the same file twice builds two themes: new revisions, same tokens
    try? withConfig { cfg in
        try write(cfg, #"{"theme": "matrix", "tokens": {"hue": 300}}"#)
        let a = Themes.load(path: cfg), b = Themes.load(path: cfg)
        #expect(a == b && a.rev != b.rev)
        #expect(a.rev != Themes.matrix.rev)
    }
}

// MARK: - model chip

@Test func modelChipFollowsWhatSetupConfigured() {
    #expect(Themes.chipText(Themes.cyan, configuredModel: "claude-sonnet-5.5") == "sonnet-5.5")
    #expect(Themes.chipText(Themes.cyan, configuredModel: "gpt-x") == "gpt-x")
    #expect(Themes.chipText(Themes.cyan, configuredModel: "") == "")
}

@Test func modelChipOverrideAndHide() {
    #expect(Themes.chipText(Themes.cyan.with { $0.modelChip = "hermes" }, configuredModel: "claude-x") == "hermes")
    #expect(Themes.chipText(Themes.cyan.with { $0.modelChip = "  " }, configuredModel: "claude-x") == "")
    #expect(Themes.chipText(Themes.cyan.with { $0.modelChip = "\u{a0}hermes\u{2003}" }, configuredModel: "") == "hermes")
}

// MARK: - saving the choice

@Test func saveChoiceCreatesTheFile() {
    withConfig { cfg in
        #expect(Themes.saveChoice("aurora", path: cfg))
        #expect(text(cfg) == "{\n  \"theme\": \"aurora\"\n}\n")  // json.dumps(indent=2) + newline
        #expect(Themes.load(path: cfg).key == "aurora")
    }
}

@Test func saveChoiceKeepsEveryOtherKey() throws {
    try withConfig { cfg in
        try write(cfg, #"{"theme": "cyan", "tokens": {"bot_name": "PIXEL", "cps": 80}, "note": [1, "é"]}"#)
        Themes.saveChoice("matrix", path: cfg)
        let saved = try PyJSON.parse(text(cfg))
        #expect(saved.dumps() == #"{"theme": "matrix", "tokens": {"bot_name": "PIXEL", "cps": 80}, "note": [1, "é"]}"#)
        #expect(text(cfg) == """
            {
              "theme": "matrix",
              "tokens": {
                "bot_name": "PIXEL",
                "cps": 80
              },
              "note": [
                1,
                "é"
              ]
            }

            """)
    }
}

@Test func saveChoiceLeavesNoTmpAndIsAReplace() throws {
    try withConfig { cfg in
        try write(cfg, #"{"theme": "cyan"}"#)
        var before = stat()
        stat(cfg.path, &before)
        Themes.saveChoice("amber", path: cfg)
        var after = stat()
        stat(cfg.path, &after)
        #expect(files(in: cfg.deletingLastPathComponent()) == ["theme.json"])
        #expect(after.st_ino != before.st_ino)  // a renamed tmp file, not an in-place rewrite
    }
}

@Test func saveChoiceWritesThroughASymlinkAndKeepsIt() throws {
    try withConfig { cfg in
        let real = cfg.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dotfiles/theme.json")
        try write(real, #"{"theme": "cyan", "tokens": {"cps": 80}}"#)
        try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cfg, withDestinationURL: real)
        #expect(Themes.saveChoice("matrix", path: cfg))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: cfg.path)) != nil)  // a dotfiles-managed config stays managed
        #expect(try PyJSON.parse(text(real)).dumps() == #"{"theme": "matrix", "tokens": {"cps": 80}}"#)
    }
}

@Test func saveChoiceFailureKeepsTheOldFileAndSwallowsTheError() throws {
    try withConfig { cfg in
        try write(cfg, #"{"theme": "cyan", "tokens": {"cps": 80}}"#)
        let before = text(cfg)
        let dir = cfg.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)  // no new files
        #expect(Themes.saveChoice("matrix", path: cfg) == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(text(cfg) == before)
        #expect(files(in: dir) == ["theme.json"])
    }
}

@Test func saveChoiceSwallowsAnUnwritableDirectory() throws {
    try withConfig { cfg in
        let blocker = cfg.deletingLastPathComponent()  // a file where the folder should be
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a file where the folder should be".utf8).write(to: blocker)
        #expect(Themes.saveChoice("matrix", path: blocker.appendingPathComponent("theme.json")) == false)
    }
}

@Test func saveChoiceNeverOverwritesAFileItCannotRead() throws {
    for content in ["{ half edited", "[1, 2]", #""x""#] {
        try withConfig { cfg in
            try write(cfg, content)
            #expect(Themes.saveChoice("matrix", path: cfg) == false)
            #expect(text(cfg) == content)
        }
    }
}

@Test func saveChoiceReplacesAnEmptyFileAndIgnoresUnknownThemes() throws {
    try withConfig { cfg in
        try write(cfg, "")
        #expect(Themes.saveChoice("matrix", path: cfg))
        #expect(Themes.saveChoice("nope", path: cfg) == false)
        #expect(try PyJSON.parse(text(cfg)).dumps() == #"{"theme": "matrix"}"#)
    }
}

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

// Spec 3.3 (with followEmotion on everywhere the card uses the same hues as the face).
private let hueTable: [String: [Double]] = [
    "cyan": [188, 168, 176, 44, 318, 34, 216, 356],
    "matrix": [128, 108, 116, 44, 318, 34, 216, 356],
    "amber": [38, 18, 26, 52, 318, 24, 216, 356],
    "aurora": [268, 248, 256, 44, 318, 34, 216, 356],
    "daylight": [196, 176, 184, 44, 318, 34, 216, 356]]

private func hueOf(_ t: Theme, _ s: (name: String, activity: String, emotion: String)) -> Double {
    Themes.hueFor(t, activity: s.activity, emotion: s.emotion, base: faceHue(s.activity, s.emotion))
}

@Test(arguments: keys)
func hueTableMatchesTheSpec(_ key: String) {
    let t = Themes.all.first { $0.key == key }!
    #expect(states.map { hueOf(t, $0) } == hueTable[key]!)
}

@Test func faceHueIsTheFacesHueTable() {
    // expressions.target(a, e).hue for a in idle/talking/thinking, from Python
    let idle: [String: Double] = ["neutral": 188, "happy": 168, "curious": 188, "proud": 44, "concerned": 34,
                                  "confused": 188, "playful": 318, "sad": 216, "calm": 176]
    #expect(emotions.allSatisfy { faceHue("idle", $0) == idle[$0] && faceHue("talking", $0) == idle[$0] })
    #expect(emotions.allSatisfy { faceHue("error", $0) == 356 && faceHue("asleep", $0) == 188 })
}

@Test func cyanReproducesTodaysFaceHuesExactly() {
    for (activity, emotion) in [("idle", "neutral"), ("talking", "happy"), ("idle", "calm"), ("idle", "proud"),
                                ("idle", "curious"), ("error", "neutral"), ("asleep", "happy"), ("thinking", "sad")] {
        let base = faceHue(activity, emotion)
        #expect(Themes.hueFor(Themes.cyan, activity: activity, emotion: emotion, base: base) == base, Comment(rawValue: "\(activity) \(emotion)"))
    }
}

@Test func errorIsRedWhateverTheThemeOrEmotion() {
    for t in Themes.all {
        for emotion in emotions {
            #expect(Themes.hueFor(t, activity: "error", emotion: emotion, base: faceHue("error", emotion)) == 356)
        }
        #expect(Themes.hueFor(t, activity: "idle", emotion: "x", base: 356) == 356)
    }
}

@Test func signalHuesKeep14DegreesFromTheRestingHue() {
    for h in stride(from: 0, to: 360, by: 5) {
        let t = Themes.cyan.with { $0.hue = Double(h) }
        for name in ["proud", "playful", "concerned", "sad"] {
            let s = states.first { $0.name == name }!
            #expect(abs(pyFloatMod(hueOf(t, s) - t.hue + 180, 360) - 180) >= 14 - 1e-9, Comment(rawValue: "\(h) \(name)"))
        }
    }
}

@Test func liveHueRule() {
    let amber = Themes.amber
    #expect(Themes.liveHue(amber, faceNow: 17, activity: "idle") == 17)  // follows the face
    let still = amber.with { $0.followEmotion = false }
    #expect(Themes.liveHue(still, faceNow: 17, activity: "idle") == 38)  // one phosphor colour
    #expect(Themes.liveHue(still, faceNow: 356, activity: "error") == 356)  // an error always turns it red
    #expect(Themes.liveHue(amber, faceNow: 365, activity: "idle") == 5)
    #expect(Themes.liveHue(amber, faceNow: -1e-20, activity: "idle") == 360)  // Python's float %
}

@Test func theAuraDriftsTowardPinkByAtMostAuraDhAndNeverJumps() {
    let aurora = Themes.aurora
    func fromPink(_ h: Double) -> Double { abs(pyFloatMod(Themes.pink - h + 180, 360) - 180) }
    for h in 0..<360 {
        let hue = Double(h), d = Themes.auraShift(aurora, hue)
        #expect(abs(d) <= aurora.auraDh)
        #expect(fromPink(hue + d) <= fromPink(hue) + 10)  // never away from pink (a little past is fine)
        #expect(abs(Themes.auraShift(aurora, hue + 1) - d) < 2)  // no jump while the face's hue sweeps
    }
    for s in states {  // every mood, error too, ends on a pink, magenta or violet, not a new hue
        let hue = hueOf(aurora, s)
        #expect(fromPink(hue + Themes.auraShift(aurora, hue)) < 60, Comment(rawValue: s.name))
    }
    #expect(Themes.auraShift(Themes.cyan, 188) == 0)  // no aura, no shift
    // the same maths, from Python
    #expect(Themes.auraShift(aurora, 188) == 43.096303272796085 && Themes.auraShift(aurora, 0) == -35.00000000000003)
    #expect(Themes.auraShift(aurora, 45.5) == -67.77033482646755 && Themes.auraShift(aurora, 150) == 8.572527594031473e-15)
    #expect(Themes.auraShift(aurora, 330) == 0)
    #expect(Themes.auraShift(aurora, 268) == 61.806331500124884 && Themes.auraShift(aurora, 356) == -30.685980275235423)
}

@Test func accentAndLabelColours() {
    let cyan = Themes.cyan
    #expect(Themes.accent(cyan, 188, alpha: 1.0) == RGBA(r: 38, g: 226, b: 255, a: 255))  // HSV(188, .85, 1.0)
    #expect(Themes.accent(cyan, 188, alpha: 0.5).a == 128)  // 127.5 rounds to the even 128, like Python's round
    #expect(Themes.accent(cyan, 548) == Themes.accent(cyan, 188))  // the hue wraps
    #expect(Themes.labelColour(cyan, 188) == RGBA(r: 135, g: 212, b: 224, a: 255))  // HSV(188, .40, .88)
    #expect(Themes.labelColour(cyan, 188, alpha: 0.1).a == 26)  // 25.5 -> 26
    #expect(Themes.accent(cyan, 0, alpha: 7).a == 255 && Themes.accent(cyan, 0, alpha: -1).a == 0)
    #expect(Themes.accent(cyan, -1e-20) == RGBA(r: 255, g: 38, b: 38, a: 255) && Themes.accent(cyan, 1e300) == Themes.accent(cyan, 0))
    #expect(Themes.accent(cyan, 0.1, alpha: 0.9999) == RGBA(r: 255, g: 39, b: 38, a: 255))
}

@Test func colourMathsMatchesPython() throws {
    // theme.accent / theme.label_colour for (hue, alpha), straight from Python
    let t = { (k: String) in Themes.all.first { $0.key == k }! }
    let samples: [(Double, Double)] = [(0, 1), (45.5, 1), (128, 1), (188, 1), (268, 0.5), (300.25, 0.1), (356, 1), (-30, 0.333), (725, 1)]
    for (key, rows) in pythonColours {
        for (i, (hue, alpha)) in samples.enumerated() {
            let (accent, label) = rows[i]
            #expect(rgb8(Themes.accent(t(key), hue, alpha: alpha)) == accent, Comment(rawValue: "\(key) accent \(hue)"))
            #expect(rgb8(Themes.labelColour(t(key), hue, alpha: alpha)) == label, Comment(rawValue: "\(key) label \(hue)"))
        }
    }
}

@Test func aHueOrAlphaThatIsNotANumberDrawsInsteadOfTrapping() {
    // Python raises ValueError here; the face's hue is never NaN, but a bad number must not take the app down
    let cyan = Themes.cyan
    for bad in [Double.nan, .infinity, -.infinity] {
        #expect(Themes.accent(cyan, bad) == Themes.accent(cyan, 0))
        #expect(Themes.labelColour(cyan, bad, alpha: 0.5) == Themes.labelColour(cyan, 0, alpha: 0.5))
    }
    #expect(Themes.accent(cyan, 188, alpha: .nan) == Themes.accent(cyan, 188))
    #expect(Themes.accent(cyan, 188, alpha: .infinity).a == 255 && Themes.accent(cyan, 188, alpha: -.infinity).a == 0)
}

@Test func rgba() {
    #expect(Themes.rgba("#04121a") == RGBA(r: 4, g: 18, b: 26, a: 255))
    #expect(Themes.rgba("#FFFFFF", alpha: 0.5) == RGBA(r: 255, g: 255, b: 255, a: 128))
}

// MARK: - WCAG contrast
// The helpers live here on purpose: the sources have no use for them.

private func lin(_ c: Int) -> Double {
    let x = Double(c) / 255
    return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
}

private func lum(_ rgb: [Int]) -> Double { 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2]) }

private func ratio(_ a: [Int], _ b: [Int]) -> Double {
    let (hi, lo) = (max(lum(a), lum(b)), min(lum(a), lum(b)))
    return (hi + 0.05) / (lo + 0.05)
}

private func rgb(_ c: String) -> [Int] { rgb(Themes.rgba(c)) }
private func rgb(_ c: RGBA) -> [Int] { [Int(c.r), Int(c.g), Int(c.b)] }
private func rgb8(_ c: RGBA) -> [Int] { rgb(c) + [Int(c.a)] }

private func over(_ fg: [Int], _ alpha: Double, _ ground: [Int]) -> [Int] {
    zip(fg, ground).map { Int((Double($0) * alpha + Double($1) * (1 - alpha)).rounded(.toNearestOrEven)) }
}

/// The card fill (both gradient stops) on the two worst wallpapers: white and black.
private func grounds(_ t: Theme) -> [[Int]] {
    [t.bgTop, t.bgBot].flatMap { stop in [[255, 255, 255], [0, 0, 0]].map { over(rgb(stop), t.bgA, $0) } }
}

/// Every hue the face can wear in this theme (all activities x all emotions).
private func emotionHues(_ t: Theme) -> Set<Double> {
    Set(["idle", "talking", "error", "asleep"].flatMap { a in
        emotions.map { e in Themes.hueFor(t, activity: a, emotion: e, base: faceHue(a, e)) }
    })
}

@Test(arguments: keys, ["text", "text_dim", "head", "link", "code_fg"])
func textHas45To1OnTheCard(_ key: String, _ token: String) {
    let t = Themes.all.first { $0.key == key }!
    for ground in grounds(t) {
        #expect(ratio(rgb(colour(t, token)), ground) >= 4.5, Comment(rawValue: "\(key) \(token) \(ground)"))
    }
}

@Test(arguments: keys)
func codeHas45To1OnItsOwnBox(_ key: String) {
    let t = Themes.all.first { $0.key == key }!
    #expect(ratio(rgb(t.codeFg), rgb(t.codeBg)) >= 4.5)
    #expect(ratio(rgb(t.text), rgb(t.inlineBg)) >= 4.5)
}

@Test(arguments: keys)
func labelHas45To1AtEveryEmotionHue(_ key: String) {
    let t = Themes.all.first { $0.key == key }!
    #expect(emotionHues(t).count >= 8)
    for hue in emotionHues(t) {
        for ground in grounds(t) {
            #expect(ratio(rgb(Themes.labelColour(t, hue)), ground) >= 4.5, Comment(rawValue: "\(key) \(hue) \(ground)"))
        }
    }
}

@Test(arguments: keys)
func labelHoldsWhileTheHueSweeps(_ key: String) {
    // The animator springs the hue linearly, so a switch passes through every hue in between.
    let t = Themes.all.first { $0.key == key }!
    for hue in 0..<360 {
        for ground in grounds(t) {
            #expect(ratio(rgb(Themes.labelColour(t, Double(hue))), ground) >= 4.5, Comment(rawValue: "\(key) \(hue) \(ground)"))
        }
    }
}

// MARK: - Python goldens

private let pythonColours: [String: [([Int], [Int])]] = [
    "cyan": [([255, 38, 38, 255], [224, 135, 135, 255]), ([255, 203, 38, 255], [224, 203, 135, 255]), ([38, 255, 67, 255], [135, 224, 147, 255]), ([38, 226, 255, 255], [135, 212, 224, 255]), ([139, 38, 255, 128], [177, 135, 224, 128]), ([255, 38, 254, 26], [224, 135, 224, 26]), ([255, 38, 53, 255], [224, 135, 141, 255]), ([255, 38, 147, 85], [224, 135, 180, 85]), ([255, 56, 38, 255], [224, 142, 135, 255])],
    "matrix": [([255, 31, 31, 255], [224, 123, 123, 255]), ([255, 201, 31, 255], [224, 200, 123, 255]), ([31, 255, 61, 255], [123, 224, 137, 255]), ([31, 225, 255, 255], [123, 211, 224, 255]), ([135, 31, 255, 128], [171, 123, 224, 128]), ([255, 31, 254, 26], [224, 123, 224, 26]), ([255, 31, 46, 255], [224, 123, 130, 255]), ([255, 31, 143, 85], [224, 123, 174, 85]), ([255, 49, 31, 255], [224, 132, 123, 255])],
    "amber": [([255, 13, 13, 255], [235, 129, 129, 255]), ([255, 196, 13, 255], [235, 209, 129, 255]), ([13, 255, 45, 255], [129, 235, 143, 255]), ([13, 223, 255, 255], [129, 221, 235, 255]), ([126, 13, 255, 128], [178, 129, 235, 128]), ([255, 13, 254, 26], [235, 129, 234, 26]), ([255, 13, 29, 255], [235, 129, 136, 255]), ([255, 13, 134, 85], [235, 129, 182, 85]), ([255, 33, 13, 255], [235, 138, 129, 255])],
    "aurora": [([255, 71, 71, 255], [235, 164, 164, 255]), ([255, 211, 71, 255], [235, 218, 164, 255]), ([71, 255, 96, 255], [164, 235, 174, 255]), ([71, 231, 255, 255], [164, 225, 235, 255]), ([157, 71, 255, 128], [197, 164, 235, 128]), ([255, 71, 254, 26], [235, 164, 234, 26]), ([255, 71, 84, 255], [235, 164, 169, 255]), ([255, 71, 163, 85], [235, 164, 199, 85]), ([255, 87, 71, 255], [235, 170, 164, 255])],
    "daylight": [([153, 18, 18, 255], [107, 13, 13, 255]), ([153, 120, 18, 255], [107, 84, 13, 255]), ([18, 153, 36, 255], [13, 107, 25, 255]), ([18, 135, 153, 255], [13, 95, 107, 255]), ([81, 18, 153, 128], [57, 13, 107, 128]), ([153, 18, 152, 26], [107, 13, 107, 26]), ([153, 18, 27, 255], [107, 13, 19, 255]), ([153, 18, 86, 85], [107, 13, 60, 85]), ([153, 30, 18, 255], [107, 21, 13, 255])],
]

// theme.THEMES through dataclasses.asdict, minus rev (Python 3.14)
private let pythonThemes = #"""
    {"cyan":{"key":"cyan","label":"Cyan HUD","dark":true,"hue":188.0,"acc_s":0.85,"acc_v":1.0,"lab_s":0.4,"lab_v":0.88,"follow_emotion":true,"face_bg":["#121a2a","#090d16"],"bg_top":"#0b1322","bg_bot":"#0e182b","bg_a":0.93,"sheen":0.05,"scan_a":0.16,"scan_px":3,"scan_c":"#000000","grid_a":0.0,"aura":0.0,"aura_dh":0.0,"shape":"cut","corner":9,"border_a":0.55,"glow":1.0,"br_len":15,"br_w":1.6,"radius":3,"text":"#e6efff","text_dim":"#a6b8d8","head":"#9fe9ff","link":"#7fd0ff","code_bg":"#050a13","code_fg":"#c4d4f0","inline_bg":"#16253d","on_accent":"#04121a","led_ok":"#3ddc8a","led_warn":"#ffb62e","led_bad":"#ff5468","body_mono":false,"text_px":14,"line_h":116,"cps":55.0,"caret":"block","caret_ms":530,"bot_name":"ROBO","model_chip":""},
    "matrix":{"key":"matrix","label":"Matrix","dark":true,"hue":128,"acc_s":0.88,"acc_v":1.0,"lab_s":0.45,"lab_v":0.88,"follow_emotion":true,"face_bg":["#04140a","#010603"],"bg_top":"#04100a","bg_bot":"#051409","bg_a":0.94,"sheen":0.03,"scan_a":0.28,"scan_px":3,"scan_c":"#000000","grid_a":0.07,"aura":0.0,"aura_dh":0.0,"shape":"cut","corner":0,"border_a":0.6,"glow":0.8,"br_len":13,"br_w":2.0,"radius":0,"text":"#c9f6d3","text_dim":"#86c99a","head":"#7dff9e","link":"#6bf0c8","code_bg":"#020a05","code_fg":"#a9e8b8","inline_bg":"#0f2a18","on_accent":"#02140a","led_ok":"#4dff88","led_warn":"#ffc640","led_bad":"#ff5a5a","body_mono":true,"text_px":13,"line_h":114,"cps":70.0,"caret":"block","caret_ms":530,"bot_name":"ROBO","model_chip":""},
    "amber":{"key":"amber","label":"Amber CRT","dark":true,"hue":38,"acc_s":0.95,"acc_v":1.0,"lab_s":0.45,"lab_v":0.92,"follow_emotion":true,"face_bg":["#1c1004","#0b0601"],"bg_top":"#150d05","bg_bot":"#1a1007","bg_a":0.94,"sheen":0.04,"scan_a":0.3,"scan_px":3,"scan_c":"#000000","grid_a":0.0,"aura":0.0,"aura_dh":0.0,"shape":"round","corner":14,"border_a":0.62,"glow":1.35,"br_len":17,"br_w":1.8,"radius":5,"text":"#ffdca8","text_dim":"#d7a868","head":"#ffc45c","link":"#ffd27a","code_bg":"#0c0703","code_fg":"#f0c98f","inline_bg":"#33200b","on_accent":"#1a0e00","led_ok":"#8dff6a","led_warn":"#ffd23a","led_bad":"#ff5a4a","body_mono":true,"text_px":13,"line_h":114,"cps":40.0,"caret":"block","caret_ms":620,"bot_name":"ROBO","model_chip":""},
    "aurora":{"key":"aurora","label":"Violet Aurora","dark":true,"hue":268,"acc_s":0.72,"acc_v":1.0,"lab_s":0.3,"lab_v":0.92,"follow_emotion":true,"face_bg":["#1a1233","#0b0719"],"bg_top":"#150d2a","bg_bot":"#1b1136","bg_a":0.93,"sheen":0.07,"scan_a":0.07,"scan_px":3,"scan_c":"#000000","grid_a":0.0,"aura":0.16,"aura_dh":70,"shape":"round","corner":16,"border_a":0.66,"glow":1.25,"br_len":18,"br_w":1.5,"radius":8,"text":"#efe8ff","text_dim":"#baa9e3","head":"#d8c4ff","link":"#b9a2ff","code_bg":"#0c0720","code_fg":"#d5c8f7","inline_bg":"#2a1c52","on_accent":"#150a33","led_ok":"#3ddc8a","led_warn":"#ffb62e","led_bad":"#ff5468","body_mono":false,"text_px":14,"line_h":116,"cps":50.0,"caret":"block","caret_ms":530,"bot_name":"ROBO","model_chip":""},
    "daylight":{"key":"daylight","label":"Daylight","dark":false,"hue":196,"acc_s":0.88,"acc_v":0.6,"lab_s":0.88,"lab_v":0.42,"follow_emotion":true,"face_bg":["#1a2a44","#0c1424"],"bg_top":"#f7fbff","bg_bot":"#e9f1fa","bg_a":0.96,"sheen":0.55,"scan_a":0.035,"scan_px":3,"scan_c":"#0a2a4a","grid_a":0.0,"aura":0.0,"aura_dh":0.0,"shape":"round","corner":12,"border_a":0.7,"glow":0.45,"br_len":14,"br_w":1.7,"radius":6,"text":"#13223a","text_dim":"#4a5f80","head":"#0a6a8a","link":"#0b63c4","code_bg":"#dde8f4","code_fg":"#24344f","inline_bg":"#d3e3f3","on_accent":"#ffffff","led_ok":"#12a05a","led_warn":"#c77700","led_bad":"#d42a3d","body_mono":false,"text_px":14,"line_h":116,"cps":55.0,"caret":"block","caret_ms":530,"bot_name":"ROBO","model_chip":""}}
    """#
