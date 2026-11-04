// The painting and widget parts of the face (begun as a port of tests/test_face.py and test_look.py; the maths are in
// RoboCoreTests). ROBO_FACE_SHEET=<folder> writes face_sheet.png there: every expression and effect, to look at.
import AppKit
import Foundation
import Testing
import RoboCore
@testable import RoboUI

extension FaceRender {
    /// The face as a bitmap (sRGB, premultiplied): the context is flipped like an NSView's.
    static func image(size: CGSize, scale: CGFloat = 1, params: FaceParams, t: Double = 0,
                      bg: (RGBA, RGBA)? = nil) -> CGImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let rect = CGRect(origin: .zero, size: size)
        render(ctx, rect: rect, params: params, t: t, bg: bg)
        return ctx.makeImage()!
    }
}

private let all = Activity.allCases
private let neutral = FaceParams.target(.idle, "neutral")

/// `p` with the eyes turned as far as the cursor can turn them (`Look.gain`, scaled by the pose's wander like the
/// animator does), toward direction `i` of 8 (0 = right, 2 = down, y-down).
private func turned(_ p: FaceParams, _ i: Int) -> FaceParams {
    var q = p
    let a = Double(i) * Double.pi / 4
    q.gazeX += Look.gain * cos(a) * p.wander
    q.gazeY += Look.gain * sin(a) * p.wander
    return q
}

// MARK: - pixels

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// RGBA bytes (premultiplied) of `image`, row 0 on top.
private func pixels(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return data
}

private func rgb(_ px: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let i = (y * w + x) * 4
    return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
}

private func paint(_ p: FaceParams, bg: (RGBA, RGBA)? = nil, size: CGSize = FaceView.size,
                   t: Double = 0.5) -> [UInt8] {
    pixels(FaceRender.image(size: size, params: p, t: t, bg: bg))
}

/// The pixel of a `side`-square face where canvas point (x, y) lands.
private func canvas(_ x: Double, _ y: Double, side: Int) -> (Int, Int) {
    let k = Double(side) * FaceRender.disc / 2 / FaceRender.reach
    return (Int(Double(side) / 2 + (x - FaceRender.W / 2) * k), Int(Double(side) / 2 + (y - FaceRender.centreY) * k))
}

/// WCAG relative luminance and contrast, written out again here so the test does not trust FaceRender's own.
private func relLum(_ r: Double, _ g: Double, _ b: Double) -> Double {
    let lin = { (c: Double) in c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}
private func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

// MARK: - the widget

@MainActor @Suite(.serialized) struct FaceViewTests {
    /// A face on a clock the test moves.
    final class Clock { var now = 100.0 }
    func face(_ clock: Clock = Clock(), seed: UInt64 = 1) -> FaceView {
        FaceView(seed: seed, clock: { clock.now })
    }

    @Test(arguments: Activity.allCases) func frameIntervalFollowsActivity(_ activity: Activity) {
        let f = face()
        f.setState(activity: activity, emotion: "neutral")
        let rates: [Activity: Int] = [.idle: 40, .sleepy: 66, .asleep: 100]
        #expect(f.frameMS == rates[activity, default: 33])
    }

    @Test func wakingReturnsToTheFastRateAtOnce() {
        let f = face()
        f.setState(activity: .asleep, emotion: "neutral")
        #expect(f.frameMS == 100)
        f.setState(activity: .listening, emotion: "neutral")
        #expect(f.frameMS == 33)
        f.setState(activity: .asleep, emotion: "neutral")
        f.setState(activity: .idle, emotion: "neutral")
        #expect(f.frameMS == 40)
    }

    /// Restarting a running timer is what setState must not do: the window calls it all the time.
    @Test func setStateLeavesTheTimerAloneWhenTheRateIsUnchanged() {
        let f = face()
        let before = f.timerStarts
        for a in [Activity.idle, .idle, .talking, .talking, .listening, .talking] {
            f.setState(activity: a, emotion: "neutral", talking: a == .talking)
        }
        #expect(f.timerStarts == before + 1)  // one restart: idle -> the fast rate
    }

    /// In the common modes the face keeps animating while a menu or a drag is tracking events.
    @Test func theTimerRunsInTheCommonModes() {
        let f = face()
        #expect(CFRunLoopContainsTimer(CFRunLoopGetMain(), f.timer, .commonModes))
        f.setState(activity: .asleep, emotion: "neutral")  // and so does the restarted one
        #expect(CFRunLoopContainsTimer(CFRunLoopGetMain(), f.timer, .commonModes))
    }

    @Test func withoutAThemeTheGoalIsTheExpressionTable() {
        let f = face()
        for (a, e) in [(Activity.idle, "neutral"), (.thinking, "curious"), (.error, "sad"), (.talking, "happy"),
                       (.asleep, "proud")] {
            f.setState(activity: a, emotion: e)
            #expect(f.goal == FaceParams.target(a, e))
        }
        #expect(f.hueFn == nil && f.bg == nil)
    }

    @Test func theHueFunctionGetsTheStateAndTheBaseHue() {
        let f = face()
        var seen: [(String, String, Double)] = []
        f.setTheme(hue: { a, e, h in seen.append((a, e, h)); return 99 }, bg: nil)
        f.setState(activity: .working, emotion: "sad")
        #expect(seen.last! == ("working", "sad", 216))  // the table's hue, before the theme's
        #expect(f.goal.hue == 99)
        var plain = f.goal
        plain.hue = 216
        #expect(plain == FaceParams.target(.working, "sad"))  // nothing else changes
        #expect(f.talking == false)
        f.setState(activity: .idle, emotion: "neutral", talking: true)
        #expect(f.talking == true && seen.last! == ("idle", "neutral", 188))
    }

    @Test func setThemeAppliesToTheStateTheFaceIsIn() {
        let f = face()
        f.setState(activity: .idle, emotion: "happy", talking: true)
        f.setTheme(hue: { _, _, _ in 7 }, bg: nil)
        #expect(f.goal.hue == 7 && f.talking)
        #expect(f.frameMS == 40)  // idle's rate: setState ran again
        f.setTheme(hue: nil, bg: nil)  // back to the plain face
        #expect(f.goal == FaceParams.target(.idle, "happy") && f.hueFn == nil)
    }

    // The resting hues the five retired themes had (188, 128, 38, 268, 196): the hue token still moves every neutral pose
    // and keeps the signal emotions 14 degrees away from it (proud gold lands near 38).
    @Test(arguments: [(188.0, 168.0, 44.0, 216.0), (128, 108, 44, 216),
                      (38, 18, 52, 216), (268, 248, 44, 216),
                      (196, 176, 44, 216)])
    func theFaceTakesTheThemesHues(_ restingHue: Double, _ happy: Double, _ proud: Double, _ sad: Double) {
        let neutral = restingHue
        let key = "hue \(Int(restingHue))"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("robo-face-theme-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try? "{\"tokens\": {\"hue\": \(Int(restingHue))}}".write(to: file, atomically: true, encoding: .utf8)
        let t = Themes.load(path: file)
        let f = face()
        f.setTheme(hue: { a, e, h in Themes.hueFor(t, activity: a, emotion: e, base: h) }, bg: nil)
        for (a, e, hue) in [(Activity.idle, "neutral", neutral), (.idle, "happy", happy), (.idle, "proud", proud),
                            (.idle, "sad", sad), (.error, "sad", 356)] {  // an error is red in every theme
            f.setState(activity: a, emotion: e)
            #expect(abs(f.goal.hue - hue) < 1e-9, "\(key) \(a) \(e)")
        }
    }

    @Test func snapSkipsTheSweepToTheNewHue() {
        let c = Clock()
        let f = face(c)
        f.setTheme(hue: { _, _, _ in 128 }, bg: nil)
        #expect(f.params.hue == 188)  // the spring would take about 0.3 s
        f.setTheme(hue: { _, _, _ in 128 }, bg: nil, snap: true)
        #expect(f.params.hue == 128 && f.anim.x?[\.hue] == 128 && f.anim.v[\.hue] == 0)
        c.now += 1.0 / 30
        f.tick()
        #expect(abs(f.params.hue - 128) < 0.5)  // and it stays there
    }

    @Test func theViewPaintsTheThemesBody() {
        let f = FaceView(seed: 1)
        let blue = RGBA(r: 0x33, g: 0x66, b: 0x99, a: 255)
        func body() -> (r: Int, g: Int, b: Int, a: Int) {
            let rep = f.bitmapImageRepForCachingDisplay(in: f.bounds)!
            f.cacheDisplay(in: f.bounds, to: rep)
            let k = rep.pixelsWide / 128
            let c = rep.colorAt(x: 40 * k, y: 110 * k)!.usingColorSpace(.sRGB)!  // low on the left, clear of the features
            return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                    Int((c.blueComponent * 255).rounded()), Int((c.alphaComponent * 255).rounded()))
        }
        f.setTheme(hue: nil, bg: (blue, blue))
        let c = body()
        #expect(abs(c.r - 0x33) <= 1 && abs(c.g - 0x66) <= 1 && abs(c.b - 0x99) <= 1 && c.a == 255)
        f.setTheme(hue: nil, bg: nil)
        let white = body()
        #expect(white.r > 220 && white.g > 220 && white.b > 220)
    }

    @Test func voiceOverSeesAButtonNamedRoboAndItsPressIsAClick() {
        let f = face()
        #expect(f.isAccessibilityElement() && f.accessibilityRole() == .button && f.accessibilityLabel() == "Robo")
        #expect(f.accessibilityHelp()?.contains("Click") == true)
        var seen: [FaceMouse] = []
        f.onMouse = { seen.append($0) }
        #expect(f.accessibilityPerformPress())
        #expect(seen == [.press, .release])  // what the window reads as a click
    }

    /// The window hands the look to the animator (tests/test_look.py).
    @Test func theWidgetHandsTheLookToTheAnimator() {
        let c = Clock()
        let f = face(c)
        f.setState(activity: .idle, emotion: "neutral")
        f.setLook(Vec(0.9, 0))
        for _ in 0..<60 { c.now += 1.0 / 30; f.tick() }
        #expect(f.params.gazeX > 0.7)
        f.setLook(nil)
        for _ in 0..<60 { c.now += 1.0 / 30; f.tick() }
        #expect(abs(f.params.gazeX) < 0.4)
    }

    @Test func mouseEventsReachTheWindowsHook() {
        let f = face()
        var seen: [FaceMouse] = []
        f.onMouse = { seen.append($0) }
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        f.mouseDown(with: e)
        f.mouseDragged(with: e)
        f.mouseUp(with: e)
        f.rightMouseDown(with: e)
        #expect(seen == [.press, .drag, .release, .rightPress])
    }
}

// MARK: - the painting

@Suite struct FaceRenderTests {
    @Test func theDefaultBodyIsTheThemesWhite() {
        #expect(FaceRender.screen == RGBA(r: 255, g: 255, b: 255, a: 255) && FaceRender.bg == RGBA(r: 226, g: 230, b: 237, a: 255))
        for (a, e) in [(Activity.idle, "neutral"), (.talking, "happy"), (.error, "sad")] {
            let p = FaceParams.target(a, e)
            let plain = paint(p)
            #expect(plain == paint(p, bg: (FaceRender.screen, FaceRender.bg)))  // pixel for pixel
            let tokens = Themes.glass.faceBg  // the same colours as theme tokens
            #expect(plain == paint(p, bg: (Themes.rgba(tokens.centre), Themes.rgba(tokens.edge))))
        }
    }

    @Test func aThemeBodyReplacesBothColours() {
        let p = neutral
        let blue = Themes.rgba("#336699")
        let px = paint(p, bg: (blue, blue))
        let c = rgb(px, 128, 40, 110)  // low on the left, clear of the features
        #expect(c.r == 0x33 && c.g == 0x66 && c.b == 0x99)
        #expect(px != paint(p))
        let rim = rgb(paint(p, bg: (Themes.rgba("#000000"), Themes.rgba("#ff0000"))), 128, 98, 100)
        #expect(rim.r > rim.b + 100)  // the edge colour is toward the rim
    }

    /// The features are ink on the white body: at every hue and every saturation the table uses, their colour keeps
    /// its hue and reads at 4.5:1 or more against both ends of the body's gradient (WCAG asks 3:1 of graphics).
    @Test func theInkReadsOnTheBodyAtEveryHue() {
        func lum(_ c: RGBA) -> Double { relLum(Double(c.r) / 255, Double(c.g) / 255, Double(c.b) / 255) }
        let body = [lum(FaceRender.screen), lum(FaceRender.bg)]
        let sats = Set(all.flatMap { a in emotions.map { FaceParams.target(a, $0).sat } }).union([1])
        var worst = 99.0
        for sat in sats {
            for hue in 0..<360 {
                let c = FaceRender.ink(hue: Double(hue), sat: sat)
                let l = relLum(c.r, c.g, c.b)
                for b in body { worst = min(worst, contrast(l, b)) }
                let back = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).hueComponent * 360
                #expect(abs(pyFloatModTest(back - Double(hue) + 180, 360) - 180) < 1, "hue \(hue) sat \(sat)")
            }
        }
        #expect(worst >= 4.5, "worst \(worst)")
    }

    @Test func theShapesAreAntialiased() {  // soft edges, not a stair of a few levels
        let px = paint(neutral)
        #expect(Set(stride(from: 0, to: px.count, by: 4).map { px[$0 + 1] }).count > 40)
    }

    /// Arcs run the way Qt's do although this context is y-down: the drop's bulge hangs below its tip.
    @Test func theSweatDropHangsDownAndThePulseArcsOpenOutward() {
        let side = 320
        var p = neutral
        p.effects = ["sweat"]
        let px = paint(p, size: CGSize(width: side, height: side), t: 0)
        func blue(_ x: Double, _ y: Double) -> Bool {
            let (i, j) = canvas(x, y, side: side)
            let c = rgb(px, side, i, j)
            return c.b > 180 && c.r < 120
        }
        #expect(blue(270, 80))  // the round part, below the middle of the drop (x = 270, tip at y = 59)
        #expect(!blue(270, 95))  // and nothing hangs below it
        #expect(blue(270, 63))  // the tip is narrow but there
        #expect(!blue(262, 62))  // 8 units beside the tip is empty

        p.effects = ["pulse"]
        let pulse = paint(p, size: CGSize(width: side, height: side), t: 0)
        func sum(_ x: Double, _ y: Double) -> Int {
            let (i, j) = canvas(x, y, side: side)
            let c = rgb(pulse, side, i, j)
            return c.r + c.g + c.b
        }
        let body = sum(47, 150)
        #expect(sum(47, 102) < body - 60)  // the left arc sits on the eye's outer (left) side, 14 out
        #expect(sum(273, 102) < body - 60)  // and the right one on the right
    }

    @Test func everyActivityAndEmotionDrawsSomethingThatIsNotBlank() {
        for a in all {
            for e in emotions {
                let px = paint(FaceParams.target(a, e))
                let distinct = Set(stride(from: 0, to: px.count, by: 4).map { Int(px[$0]) << 16 | Int(px[$0 + 1]) << 8 | Int(px[$0 + 2]) })
                #expect(distinct.count > 20, "\(a) \(e)")
            }
        }
    }

    @Test func theFaceIsAWhiteDiscAndTransparentAroundIt() {
        let px = paint(neutral)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { px[(y * 128 + x) * 4 + 3] }
        #expect(alpha(0, 0) == 0 && alpha(127, 0) == 0 && alpha(0, 127) == 0 && alpha(127, 127) == 0)  // corners: clear
        #expect(alpha(20, 20) == 0)  // still outside the disc (radius 56 around 64, 64)
        #expect(alpha(64, 9) == 255 && alpha(9, 64) == 255)  // just inside its top and left edges
        let mid = rgb(px, 128, 40, 110)  // low on the left, clear of the eyes and the mouth
        #expect(mid.r > 220 && mid.g > 220 && mid.b > 220 && alpha(40, 110) == 255)
        #expect(alpha(64, 122) > 0 && alpha(64, 122) < 80)  // the soft shadow under the disc
        #expect(alpha(64, 1) < alpha(64, 122))  // which hangs below it
    }

    /// Nothing is cut by the circle: in the outer ring of the disc (6 to 2 canvas units from its edge) every pixel is
    /// still the body, for every pose with the eyes turned as far as they go and every effect through its animation.
    @Test func noFeatureOrEffectReachesTheEdgeOfTheDisc() {
        let side = 256, k = Double(side) * FaceRender.disc / 2 / FaceRender.reach  // px per canvas unit, at 2x
        var ring: [Int] = []
        for y in 0..<side {
            for x in 0..<side {
                let r = hypot(Double(x) + 0.5 - Double(side) / 2, Double(y) + 0.5 - Double(side) / 2) / k
                if r >= FaceRender.reach - 6 && r <= FaceRender.reach - 2 { ring.append((y * side + x) * 4) }
            }
        }
        var faces: [(String, FaceParams, Double)] = []
        for a in all {
            for e in emotions {
                var p = FaceParams.target(a, e)
                p.mouthOpen = max(p.mouthOpen, a == .talking ? 1 : 0)
                for i in 0..<8 { faces.append(("\(a) \(e) look \(i)", turned(p, i), 0.6)) }
            }
        }
        for fx in ["blush", "sweat", "question", "zzz", "dots", "gear", "pulse", "sparkle"] {
            var p = neutral
            p.effects = [fx]
            for t in stride(from: 0.0, to: 5.0, by: 0.2) { faces.append((fx, p, t)) }
        }
        for (name, p, t) in faces {
            let px = pixels(FaceRender.image(size: CGSize(width: 128, height: 128), scale: 2, params: p, t: t))
            let bad = ring.filter { px[$0] < 200 || px[$0 + 1] < 200 || px[$0 + 2] < 200 }.count
            #expect(bad == 0, "\(name) t \(t)")
        }
    }
}

/// Python's float `%` (as RoboCore's `pyFloatMod`, which is internal there).
private func pyFloatModTest(_ a: Double, _ b: Double) -> Double {
    let m = fmod(a, b)
    return m < 0 ? m + b : m
}

// MARK: - the contact sheet (ROBO_FACE_SHEET=<folder>): every expression and effect, to look at

private func save(_ image: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

private let sheetDir = ProcessInfo.processInfo.environment["ROBO_FACE_SHEET"].map { URL(fileURLWithPath: $0) }

@Suite struct FaceSheet {
    /// Activities x emotions at 1x, then each effect (and a wink, an open mouth, the gaze extremes) at 2x and 1x
    /// over two effect times; the left half over white, the right half over a dark grey.
    @Test(.enabled(if: sheetDir != nil)) func contactSheet() throws {
        let dir = try #require(sheetDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let side = Int(FaceView.size.width)
        var extras: [(String, FaceParams)] = ["blush", "sweat", "question", "zzz", "dots", "gear", "pulse", "sparkle"].map {
            var p = neutral
            p.effects = [$0]
            return ($0, p)
        }
        var p = FaceParams.target(.talking, "playful")
        p.mouthOpen = 1
        extras.append(("open", p))
        for i in [5, 7, 3, 1] { extras.append(("gaze", turned(FaceParams.target(.idle, "curious"), i))) }
        let cols = emotions.count, gridH = all.count * side
        let extraRows = (extras.count + 3) / 4
        let half = cols * side
        let H = gridH + extraRows * 2 * side * 2
        let ctx = CGContext(data: nil, width: half * 2, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (x, grey) in [(0, 1.0), (half, 0.16)] {
            ctx.setFillColor(CGColor(gray: grey, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: half, height: H))
        }
        func put(_ img: CGImage, _ x: Int, _ yTop: Int) {
            ctx.draw(img, in: CGRect(x: x, y: H - yTop - img.height, width: img.width, height: img.height))
        }
        for x0 in [0, half] {
            for (r, a) in all.enumerated() {
                for (c, e) in emotions.enumerated() {
                    put(FaceRender.image(size: FaceView.size, params: FaceParams.target(a, e), t: 0.6), x0 + c * side, r * side)
                }
            }
            for (i, (_, q)) in extras.enumerated() {
                let row = i / 4, col = i % 4
                for (j, t) in [0.6, 1.7].enumerated() {
                    put(FaceRender.image(size: FaceView.size, scale: 2, params: q, t: t),
                        x0 + col * 2 * side, gridH + (row * 2 + j) * 2 * side)
                }
            }
        }
        save(ctx.makeImage()!, dir.appendingPathComponent("face_sheet.png"))
    }
}
