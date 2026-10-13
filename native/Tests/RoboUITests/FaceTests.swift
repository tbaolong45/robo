// Port of the painting and widget parts of tests/test_face.py and test_look.py (the maths are in RoboCoreTests),
// plus the visual comparison with the Python face (scripts/face_snapshots.py): set ROBO_FACE_REF to its
// output folder (and ROBO_FACE_OUT to a folder for our PNGs) to run it.
import AppKit
import Foundation
import Testing
import RoboCore
@testable import RoboUI

extension FaceRender {
    /// The face as a bitmap (sRGB, premultiplied): the context is flipped like an NSView's, `radius` > 0
    /// clips it to a rounded screen with transparent corners.
    static func image(size: CGSize, scale: CGFloat = 1, params: FaceParams, t: Double = 0,
                      bg: (RGBA, RGBA)? = nil, radius: CGFloat = 0) -> CGImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let rect = CGRect(origin: .zero, size: size)
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
        }
        render(ctx, rect: rect, params: params, t: t, bg: bg)
        return ctx.makeImage()!
    }
}

private let all = Activity.allCases
private let neutral = FaceParams.target(.idle, "neutral")

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

private func paint(_ p: FaceParams, bg: (RGBA, RGBA)? = nil, size: CGSize = CGSize(width: 64, height: 48),
                   t: Double = 0.5) -> [UInt8] {
    pixels(FaceRender.image(size: size, params: p, t: t, bg: bg))
}

/// Mean absolute difference of the RGB channels, 0...255.
private func mad(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var sum = 0, n = 0
    for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
        for c in 0..<3 { sum += abs(Int(a[i + c]) - Int(b[i + c])); n += 1 }
    }
    return Double(sum) / Double(n)
}

// MARK: - the widget

@MainActor @Suite(.serialized) struct FaceViewTests {
    /// A face on a clock the test moves.
    final class Clock { var now = 100.0 }
    func face(_ clock: Clock = Clock(), seed: UInt64 = 1) -> FaceView {
        FaceView(radius: 0, seed: seed, clock: { clock.now })
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

    @Test(arguments: [("cyan", 188.0, 168.0, 44.0, 216.0), ("matrix", 128, 108, 44, 216),
                      ("amber", 38, 18, 52, 216), ("aurora", 268, 248, 44, 216),
                      ("daylight", 196, 176, 44, 216)])
    func theFaceTakesTheThemesHues(_ key: String, _ neutral: Double, _ happy: Double, _ proud: Double, _ sad: Double) {
        let t = Themes.all.first { $0.key == key }!
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

    @Test func theViewPaintsTheThemesScreen() {
        let f = FaceView(radius: 0, seed: 1)
        f.frame = CGRect(x: 0, y: 0, width: 160, height: 120)
        let blue = RGBA(r: 0x33, g: 0x66, b: 0x99, a: 255)
        func corner() -> (r: Int, g: Int, b: Int) {
            let rep = f.bitmapImageRepForCachingDisplay(in: f.bounds)!
            f.cacheDisplay(in: f.bounds, to: rep)
            let c = rep.colorAt(x: 1, y: 1)!.usingColorSpace(.sRGB)!
            return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                    Int((c.blueComponent * 255).rounded()))
        }
        f.setTheme(hue: nil, bg: (blue, blue))
        let c = corner()
        #expect(abs(c.r - 0x33) <= 1 && abs(c.g - 0x66) <= 1 && abs(c.b - 0x99) <= 1)
        f.setTheme(hue: nil, bg: nil)
        #expect(corner() != c)
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
    @Test func theDefaultScreenIsTheDarkBlueItAlwaysWas() {
        #expect(FaceRender.screen == RGBA(r: 18, g: 26, b: 42, a: 255) && FaceRender.bg == RGBA(r: 9, g: 13, b: 22, a: 255))
        for (a, e) in [(Activity.idle, "neutral"), (.talking, "happy"), (.error, "sad")] {
            let p = FaceParams.target(a, e)
            let plain = paint(p)
            #expect(plain == paint(p, bg: (FaceRender.screen, FaceRender.bg)))  // pixel for pixel
            let tokens = Themes.cyan.faceBg  // the same colours as theme tokens
            #expect(plain == paint(p, bg: (Themes.rgba(tokens.centre), Themes.rgba(tokens.edge))))
        }
    }

    @Test func aThemeScreenReplacesBothColours() {
        let p = neutral
        let blue = Themes.rgba("#336699")
        let px = paint(p, bg: (blue, blue))
        let c = rgb(px, 64, 1, 1)  // a corner, clear of the face
        #expect(c.r == 0x33 && c.g == 0x66 && c.b == 0x99)
        #expect(px != paint(p))
        let corner = rgb(paint(p, bg: (Themes.rgba("#000000"), Themes.rgba("#ff0000"))), 64, 1, 1)
        #expect(corner.r > corner.b + 100)  // the edge colour is at the corners
    }

    /// The 5 %-alpha halo layers have no visible edge, so antialiasing them is pure cost (about 4x at idle):
    /// with it off, a pixel is covered by 0...7 layers and never by a fraction of one.
    @Test func glowLayersSkipAntialiasingButTheSolidShapesKeepIt() {
        let w = 64, h = 48
        func alphas(antialiased: Bool) -> Set<UInt8> {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let path = CGPath(roundedRect: CGRect(x: 20.3, y: 14.2, width: 17, height: 11), cornerWidth: 5,
                              cornerHeight: 5, transform: nil)
            var p = neutral
            p.glow = 1
            if antialiased {  // the same strokes, antialiased: what the halo would cost without the switch
                for i in 0..<7 {
                    ctx.addPath(path)
                    ctx.setStrokeColor(CGColor(red: 0, green: 1, blue: 1, alpha: 0.045 * 1.3))
                    ctx.setLineWidth(CGFloat(30 - 4 * i))
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    ctx.strokePath()
                }
            } else {
                FaceRender.glow(ctx, path, p)
            }
            return Set(stride(from: 3, to: data.count, by: 4).map { data[$0] })
        }
        #expect(alphas(antialiased: false).count <= 8)
        #expect(alphas(antialiased: true).count > 8)
        // and the face as a whole still draws its solid shapes smoothly: soft edges, not a stair of 8 levels
        let px = paint(neutral, size: CGSize(width: 128, height: 96))
        let edge = Set(stride(from: 0, to: 128 * 96 * 4, by: 4).map { px[$0 + 1] })
        #expect(edge.count > 40)
    }

    /// Arcs run the way Qt's do although this context is y-down: the drop's bulge hangs below its tip.
    @Test func theSweatDropHangsDownAndThePulseArcsOpenOutward() {
        var p = neutral
        p.effects = ["sweat"]
        let px = paint(p, size: CGSize(width: 320, height: 240), t: 0)  // 1 canvas unit = 1 px
        func blue(_ x: Int, _ y: Int) -> Bool { let c = rgb(px, 320, x, y); return c.b > 200 && c.g > 150 && c.r < 160 }
        #expect(blue(270, 80))  // the round part, below the middle of the drop (x = 270, tip at y = 59)
        #expect(!blue(270, 95))  // and nothing hangs below it
        #expect(blue(270, 62))  // the tip is narrow but there
        #expect(!blue(263, 62))  // 7 px beside the tip is empty

        p.effects = ["pulse"]
        let pulse = paint(p, size: CGSize(width: 320, height: 240), t: 0)
        let outer = rgb(pulse, 320, 57 - 18, 102), inside = rgb(pulse, 320, 57 - 6, 150)
        #expect(outer.b > inside.b + 20)  // the left pulse arc sits on the eye's outer (left) side
        let right = rgb(pulse, 320, 263 + 18, 102)
        #expect(right.b > inside.b + 20)
    }

    @Test func everyActivityAndEmotionDrawsSomethingThatIsNotBlank() {
        for a in all {
            for e in emotions {
                let px = paint(FaceParams.target(a, e), size: CGSize(width: 128, height: 96))
                let distinct = Set(stride(from: 0, to: px.count, by: 4).map { Int(px[$0]) << 16 | Int(px[$0 + 1]) << 8 | Int(px[$0 + 2]) })
                #expect(distinct.count > 20, "\(a) \(e)")
            }
        }
    }

    @Test func aRoundedScreenIsTransparentOutsideItsCorners() {
        let img = FaceRender.image(size: FaceView.size, params: neutral, radius: 22)
        let px = pixels(img)
        #expect(px[3] == 0)  // the top-left pixel is outside the rounded corner
        #expect(px[((48 * 128) + 64) * 4 + 3] == 255)  // the middle is solid
    }
}

// MARK: - the Python face, side by side

private func png(_ url: URL) -> CGImage? {
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { return nil }
    return rep.cgImage
}

private func save(_ image: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

private let refDir = ProcessInfo.processInfo.environment["ROBO_FACE_REF"].map { URL(fileURLWithPath: $0) }
private let outDir = ProcessInfo.processInfo.environment["ROBO_FACE_OUT"].map { URL(fileURLWithPath: $0) }
private let extraDir = ProcessInfo.processInfo.environment["ROBO_FACE_EXTRA"].map { URL(fileURLWithPath: $0) }
private let widgetDir = ProcessInfo.processInfo.environment["ROBO_FACE_WIDGET"].map { URL(fileURLWithPath: $0) }

@Suite struct FaceSnapshotTests {
    private static let cw = 240, ch = 180

    private func tile(_ p: FaceParams, t: Double = 0.6, bg: (RGBA, RGBA)? = nil) -> CGImage {
        FaceRender.image(size: CGSize(width: Self.cw, height: Self.ch), params: p, t: t, bg: bg)
    }

    /// Writes our tiles and a diff grid next to the Python ones and prints the mean absolute differences.
    @Test(.enabled(if: refDir != nil)) func everyFaceAgainstThePythonOne() throws {
        let ref = try #require(refDir)
        let out = outDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("face_swift")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var rows: [(Activity, [(String, Double)])] = []
        var worst = ("", 0.0)
        var total = 0.0, count = 0
        let cell = CGSize(width: Self.cw, height: Self.ch)
        let grid = CGContext(data: nil, width: Self.cw * 9, height: Self.ch * all.count, bitsPerComponent: 8,
                             bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let diffGrid = CGContext(data: nil, width: Self.cw * 9, height: Self.ch * all.count, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (r, a) in all.enumerated() {
            var cells: [(String, Double)] = []
            for (c, e) in emotions.enumerated() {
                let mine = tile(FaceParams.target(a, e))
                save(mine, out.appendingPathComponent("\(a.rawValue)_\(e).png"))
                let theirs = try #require(png(ref.appendingPathComponent("\(a.rawValue)_\(e).png")))
                let (pm, pt) = (pixels(mine), pixels(theirs))
                let d = mad(pm, pt)
                cells.append((e, d))
                total += d
                count += 1
                if d > worst.1 { worst = ("\(a.rawValue)_\(e)", d) }
                // CGContext rows are bottom-up: row r is drawn from the top
                let rect = CGRect(x: CGFloat(c * Self.cw), y: CGFloat((all.count - 1 - r) * Self.ch), width: cell.width, height: cell.height)
                grid.draw(mine, in: rect)
                var amplified = pm
                for i in stride(from: 0, to: pm.count, by: 4) {
                    for k in 0..<3 { amplified[i + k] = UInt8(min(255, 4 * abs(Int(pm[i + k]) - Int(pt[i + k])))) }
                    amplified[i + 3] = 255
                }
                let img = amplified.withUnsafeMutableBytes { raw -> CGImage in
                    CGContext(data: raw.baseAddress, width: Self.cw, height: Self.ch, bitsPerComponent: 8,
                              bytesPerRow: Self.cw * 4, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
                }
                diffGrid.draw(img, in: rect)
            }
            rows.append((a, cells))
        }
        save(grid.makeImage()!, out.appendingPathComponent("swift_grid.png"))
        save(diffGrid.makeImage()!, out.appendingPathComponent("diff_grid_x4.png"))
        var report = ""
        for (a, cells) in rows {
            report += String(format: "%-10@", a.rawValue as NSString)
                + cells.map { String(format: "%5.2f", $0.1) }.joined(separator: " ") + "\n"
        }
        report += String(format: "mean %.3f, worst %@ %.3f over %d tiles\n", total / Double(count), worst.0, worst.1, count)
        try report.write(to: out.appendingPathComponent("mad.txt"), atomically: true, encoding: .utf8)
        print(report)
        #expect(total / Double(count) < 3.0)
    }

    /// Gaze, bob, open mouths, wink, a half blink and the two themed screens, at two effect times.
    @Test(.enabled(if: extraDir != nil)) func extraFacesAgainstThePythonOne() throws {
        let dir = try #require(extraDir)
        let out = outDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("face_swift")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("cases.json")))
            as! [String: [String: Any]]
        var report = ""
        for name in json.keys.sorted() {
            let spec = json[name]!, d = spec["params"] as! [String: Any]
            var p = FaceParams()
            func num(_ k: String) -> Double { (d[k] as! NSNumber).doubleValue }
            p.eyeW = num("eye_w"); p.eyeH = num("eye_h"); p.eyeRound = num("eye_round"); p.gazeX = num("gaze_x")
            p.gazeY = num("gaze_y"); p.lidTop = num("lid_top"); p.lidAngle = num("lid_angle")
            p.lidBottom = num("lid_bottom"); p.skew = num("skew"); p.wink = num("wink")
            p.mouthCurve = num("mouth_curve"); p.mouthOpen = num("mouth_open"); p.mouthW = num("mouth_w")
            p.hue = num("hue"); p.sat = num("sat"); p.glow = num("glow"); p.wander = num("wander"); p.bob = num("bob")
            p.effects = Set(d["effects"] as! [String])
            let bg = (spec["bg"] as? [String]).map { (Themes.rgba($0[0]), Themes.rgba($0[1])) }
            for t in [0.6, 1.7] {
                let mine = tile(p, t: t, bg: bg)
                save(mine, out.appendingPathComponent("\(name)_\(t).png"))
                let theirs = try #require(png(dir.appendingPathComponent("\(name)_\(t).png")))
                report += String(format: "%-18@ t=%.1f  mad %.3f\n", name as NSString, t, mad(pixels(mine), pixels(theirs)))
            }
        }
        try report.write(to: out.appendingPathComponent("mad_extra.txt"), atomically: true, encoding: .utf8)
        print(report)
    }

    /// The real widget (QWidget.grab on macOS, 72 dpi: text is 26 px, not the 34 px of a 96 dpi QImage).
    @Test(.enabled(if: widgetDir != nil)) func widgetGrabsAgainstThePythonWidget() throws {
        let dir = try #require(widgetDir)
        let out = outDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("face_swift")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report = ""
        for (a, e) in [(Activity.idle, "confused"), (.asleep, "neutral"), (.idle, "concerned"),
                       (.thinking, "neutral"), (.working, "neutral")] {
            let mine = tile(FaceParams.target(a, e))
            save(mine, out.appendingPathComponent("widget_\(a.rawValue)_\(e).png"))
            let theirs = try #require(png(dir.appendingPathComponent("\(a.rawValue)_\(e).png")))
            report += String(format: "%-8@ %-9@ mad %.3f\n", a.rawValue as NSString, e as NSString, mad(pixels(mine), pixels(theirs)))
        }
        try report.write(to: out.appendingPathComponent("mad_widget.txt"), atomically: true, encoding: .utf8)
        print(report)
    }
}
