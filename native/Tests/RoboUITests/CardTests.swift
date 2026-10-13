// Port of the card parts of tests/test_hud.py and tests/test_chat_ui.py: the frame and its cache, the header and its lights, the
// quote, the caret, the picker, the menu grid, the approval, the sizing and scrolling of the reply, the skip click.
// Not ported, because they have no meaning here: the Qt style sheet tests (`qss` parses, uses the tokens: there is no style sheet,
// the same tokens are read by the painting code), "the picker is one grid, not nested rows" (a Qt shutdown crash), the
// QLayout-based assertions (the card lays out by hand), the docked window.
import AppKit
import Foundation
import Testing
@testable import RoboCore
@testable import RoboUI

private let keys = Themes.all.map(\.key)

// MARK: helpers

@MainActor private func makeCard(_ t: Theme = Themes.cyan, watch: Bool = false, model: String = "") -> CardView {
    _ = NSApplication.shared
    let card = CardView(theme: t, hasWatch: watch, model: model)
    card.renderBudget = .infinity  // a slow machine must not make a test skip a render
    card.setFrameSize(NSSize(width: CardView.width, height: max(200, card.fittingHeight)))
    return card
}

/// RGBA, premultiplied, whatever the source format was.
private struct Bitmap {
    let width: Int, height: Int
    private var data: [UInt8]
    init(_ image: CGImage) {
        width = image.width; height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    func at(_ x: Double, _ y: Double, dpr: Double = 1) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (Int((y * dpr).rounded()) * width + Int((x * dpr).rounded())) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
    func alpha(_ x: Double, _ y: Double, dpr: Double = 1) -> Int { at(x, y, dpr: dpr).a }
    /// The pixel with its colour un-premultiplied (a translucent dot still has the dot's colour).
    func straight(_ x: Double, _ y: Double, dpr: Double = 1) -> (r: Int, g: Int, b: Int, a: Int) {
        let p = at(x, y, dpr: dpr), a = Double(max(1, p.a)) / 255
        return (Int(Double(p.r) / a), Int(Double(p.g) / a), Int(Double(p.b) / a), p.a)
    }
    /// The hue in degrees of the (un-premultiplied) pixel.
    func hue(_ x: Double, _ y: Double, dpr: Double = 1) -> Double {
        let p = at(x, y, dpr: dpr), a = Double(max(1, p.a)) / 255
        return Double(NSColor(srgbRed: Double(p.r) / 255 / a, green: Double(p.g) / 255 / a, blue: Double(p.b) / 255 / a, alpha: 1).hueComponent) * 360
    }
    var bytes: [UInt8] { data }
}

@MainActor private func snap(_ view: NSView, scale: CGFloat = 1) -> CGImage {
    let ctx = CGContext(data: nil, width: Int((view.bounds.width * scale).rounded()), height: Int((view.bounds.height * scale).rounded()), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    view.displayIgnoringOpacity(view.bounds, in: g)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

private func angle(_ a: Double, _ b: Double) -> Double { abs((a - b + 180).truncatingRemainder(dividingBy: 360) - 180) }

private let longReply = (0..<24).map { "Paragraph \($0) with a few words in it." }.joined(separator: "\n\n")

// MARK: the frame

@Suite @MainActor struct CardFrameTests {
    @Test func theCardIsAsWideAsTheOldPanelAndPutsTheHeaderInTheFrame() {
        let card = makeCard()
        #expect(card.frame.width == CardView.width && CardView.width == 340)
        #expect(card.header.frame == NSRect(x: 6, y: 6, width: 328, height: 26))  // inside the 6 px glow margin
        card.setFrameSize(NSSize(width: 340, height: 330))
        #expect(card.header.frame == NSRect(x: 6, y: 6, width: 328, height: 26))
        #expect(card.isFlipped)
    }

    @Test func theColumnHasThePythonMarginsAndSpacingAndHiddenItemsTakeNoRoom() {
        let card = makeCard()
        #expect(card.fittingHeight == 61.0)  // nothing shows: top margin and the tail's 19
        card.showMenu(stay: "📌 Stay", watch: "⏸ Watch")
        card.togglePicker()
        #expect(card.fittingHeight == 184.0)  // 42 + 62 + 8 + 53 + 19
        #expect(card.chips.frame == NSRect(x: 19, y: 42, width: 302, height: 62))
        #expect(card.picker.frame == NSRect(x: 19, y: 112, width: 302, height: 53))
        card.hideMenu()
        #expect(card.fittingHeight == 61)
    }

    @Test(arguments: keys) func theFrameHasTheCornersAndTheTailTheThemeAsksFor(_ key: String) {
        let t = Themes.all.first { $0.key == key }!, dpr = 2.0
        let img = Bitmap(Chrome.frame(t, size: CGSize(width: 340, height: 200), dpr: dpr, hue: t.hue)!)
        #expect(img.width == 680 && img.height == 400)
        #expect(img.alpha(170, 100, dpr: dpr) >= Int(0.9 * 255) - 2)  // glass: never more see-through than 10 %
        #expect(img.alpha(1, 1, dpr: dpr) == 0)  // outside everything
        if t.corner > 0 { #expect(img.alpha(7, 7, dpr: dpr) < 40) } else { #expect(img.alpha(8, 8, dpr: dpr) >= 200) }  // chamfered or rounded: the very corner is empty
        // the frame's bottom edge is at y = 190.5; the tail is a notch under it, centred
        #expect(img.alpha(170, 195, dpr: dpr) >= 200 && img.alpha(170, 198, dpr: dpr) > 0)
        #expect(img.alpha(185, 195, dpr: dpr) < 40 && img.alpha(155, 195, dpr: dpr) < 40)
        #expect(img.alpha(100, 197, dpr: dpr) == 0)  // below the frame, away from the tail
    }

    @Test(arguments: keys) func theFillIsTheThemesGlass(_ key: String) {
        let t = Themes.all.first { $0.key == key }!
        let p = Bitmap(Chrome.frame(t, size: CGSize(width: 340, height: 200), dpr: 1, hue: t.hue)!).at(170, 175)  // under the content, past the sheen
        let want = Themes.rgba(t.bgBot)
        #expect(abs(p.r - Int(want.r)) < 40 && abs(p.g - Int(want.g)) < 40 && abs(p.b - Int(want.b)) < 40)
        let lightness = (max(p.r, p.g, p.b) + min(p.r, p.g, p.b)) / 2
        #expect((lightness > 150) == !t.dark)
    }

    @Test func theFrameFollowsTheHueAndTheGlowStaysInsideItsMargin() {
        let a = Bitmap(Chrome.frame(Themes.cyan, size: CGSize(width: 340, height: 200), dpr: 1, hue: 188)!)
        let b = Bitmap(Chrome.frame(Themes.cyan, size: CGSize(width: 340, height: 200), dpr: 1, hue: 356)!)  // error: red
        let arm = { (i: Bitmap) in i.at(20, 6) }  // on the top left corner bracket
        #expect(arm(a).b > 200 && 200 > arm(a).r && arm(b).r > 200 && 200 > arm(b).b)
        for img in [a, b] {  // nothing painted in the outermost pixels except the tail's dot
            let edge = [0, 339].flatMap { x in (0..<190).map { img.alpha(Double(x), Double($0)) } } + (0..<340).map { img.alpha(Double($0), 0) }
            #expect(edge.max() == 0)
        }
    }

    @Test func theAuroraBorderEndsOnPinkForEveryMoodAndAnErrorStaysRed() {
        let aurora = Themes.aurora
        for (activity, emotion) in [(Activity.idle, "neutral"), (.talking, "happy"), (.idle, "proud"), (.idle, "playful"), (.idle, "concerned"), (.idle, "sad"), (.error, "neutral")] {
            let hue = Themes.hueFor(aurora, activity: activity.rawValue, emotion: emotion, base: FaceParams.target(activity, emotion).hue)
            let edge = Bitmap(Chrome.frame(aurora, size: CGSize(width: 340, height: 200), dpr: 1, hue: hue)!).hue(333, 130)  // the right edge, past the sweep's 90 %
            #expect(angle(edge, 330) < 75, "\(emotion) at \(hue) ended on \(edge)")  // not yellow or green
        }
    }
}

// MARK: the cache

@Suite @MainActor struct CardCacheTests {
    @Test func theFrameImageIsRebuiltOnlyWhenWhatItShowsChanges() {
        let card = makeCard()
        let first = card.frameImage(dpr: 2)!
        #expect(card.frameImage(dpr: 2) === first && card.frameBuilds == 1)  // a hit
        #expect(card.setHue(card.hue + 0.6) == false && card.frameImage(dpr: 2) === first)  // same 2 degree step
        card.setTheme(card.theme)  // nothing new
        #expect(card.frameImage(dpr: 2) === first)
        #expect(card.setHue(card.hue + 40) == true)
        let hueStep = card.frameImage(dpr: 2)!
        #expect(hueStep !== first && card.frameImage(dpr: 2) === hueStep)
        card.setTheme(Themes.matrix)
        let themed = card.frameImage(dpr: 2)!
        #expect(themed !== hueStep)
        card.setFrameSize(NSSize(width: 340, height: 260))
        let resized = card.frameImage(dpr: 2)!
        #expect(resized !== themed && resized.size.height == 260)
        card.setTheme(Themes.matrix.with { $0.glow = 0 })  // a user token: a new revision
        #expect(card.frameImage(dpr: 2) !== resized)
        let before = card.frameBuilds
        _ = card.frameImage(dpr: 1)  // another pixel ratio is another image
        #expect(card.frameBuilds == before + 1)
    }

    @Test func hueIsFollowedInTwoDegreeStepsAndWraps() {
        let card = makeCard()
        card.setHue(359.2)
        #expect(card.hue == 0)
        card.setHue(101)
        #expect(card.hue == 100)  // Python's round is half to even: 50.5 -> 50
        card.setHue(103)
        #expect(card.hue == 104 && card.hue.truncatingRemainder(dividingBy: 2) == 0)
        #expect(Chrome.quantised(-1) == 0 || Chrome.quantised(-1) == 358)
    }

    @Test func aHueChangeRestylesEveryWidgetInTheTree() {
        let card = makeCard()
        card.setHue(300)
        #expect(card.header.hue == 300 && card.quote.background.hue == 300 && card.statusRow.dots.hue == 300 && card.caret.hue == 300)
        for l in [card.quote.label, card.quote.followUp, card.statusRow.label, card.approval.label, card.picker.label] { #expect(l.hue == 300) }
        card.setTheme(Themes.aurora)
        #expect(card.header.theme == Themes.aurora && card.caret.theme == Themes.aurora && card.statusRow.dots.theme == Themes.aurora)
        #expect(card.picker.label.text == "THEME ▸ VIOLET AURORA")
        #expect(card.header.hue == 300)  // the theme change leaves the live hue to the window
    }

    @Test func theCardStartsInItsOwnThemeAndRestingHue() {
        for t in Themes.all {
            let card = makeCard(t)
            #expect(card.header.theme.key == t.key && card.hue == Chrome.quantised(t.hue))
        }
    }
}

// MARK: lights and header

@Suite @MainActor struct CardHeaderTests {
    @Test(arguments: [("unknown", "HERMES"), ("ok", "HERMES"), ("warn", "HERMES …"), ("bad", "HERMES ✕")])
    func theHermesLightAlwaysCarriesAWord(_ state: String, _ label: String) {
        let led = Led("HERMES", state: LedState(rawValue: state)!)
        #expect(led.label == label && led.width > 14 + 20)
    }

    @Test(arguments: [("ok", "MIC"), ("loading", "MIC …"), ("hot", "LISTENING"), ("off", "MIC OFF"), ("bad", "MIC ✕")])
    func theMicLightAlwaysCarriesAWord(_ state: String, _ label: String) {
        #expect(Led("MIC", hot: "LISTENING", state: LedState(rawValue: state)!).label == label)
    }

    @Test func aStateThatMeansTroubleIsNotToldByColourAlone() {
        let labels = ["ok", "loading", "hot", "off", "bad"].map { Led("MIC", hot: "LISTENING", state: LedState(rawValue: $0)!).label }
        #expect(Set(labels).count == 5)  // five states, five different words
        #expect(LedState.allCases.count == 7)
    }

    @Test func micStateReadsTheListenerTheMindAndTheNote() {
        #expect(CardView.micState(listenerReady: nil, activity: .idle, noted: false) == .off)
        #expect(CardView.micState(listenerReady: nil, activity: .listening, noted: false) == .off)  // no listener: nothing is listening
        #expect(CardView.micState(listenerReady: false, activity: .idle, noted: false) == .loading)
        #expect(CardView.micState(listenerReady: true, activity: .idle, noted: false) == .ok)
        #expect(CardView.micState(listenerReady: true, activity: .listening, noted: false) == .hot)
        #expect(CardView.micState(listenerReady: true, activity: .idle, noted: true) == .bad)
        #expect(CardView.micState(listenerReady: false, activity: .idle, noted: true) == .bad)
        #expect(CardView.micState(listenerReady: true, activity: .listening, noted: true) == .hot)  // the next wake clears it
    }

    @Test func theHeaderLaysOutAgainWhenALabelGrows() {
        let card = makeCard()
        card.setLights(link: .ok, mic: .ok)
        let before = card.header.micX
        card.setLights(link: .bad, mic: .hot)  // "HERMES ✕" is wider than "HERMES"
        #expect(card.header.link.label == "HERMES ✕" && card.header.mic.label == "LISTENING")
        #expect(card.header.micX > before)
        #expect(card.header.micX >= card.header.linkX + card.header.link.width)
        #expect(card.header.micX + card.header.mic.width <= card.header.bounds.width)
    }

    @Test func blinkingAndPulsingFollowThePhaseTheWindowGives() {
        var warn = Led("HERMES", state: .warn)
        #expect(warn.setPhase(0.0) == false)  // lit for half a second, dark for half, at 1 Hz
        #expect(warn.setPhase(0.6) && !warn.lit)
        #expect(warn.setPhase(1.0) && warn.lit)
        var ok = Led("HERMES", state: .ok)
        #expect((0...4).allSatisfy { ok.setPhase(Double($0) * 0.1) == false })  // steady: nothing to redraw
        var hot = Led("MIC", hot: "LISTENING", state: .hot)
        #expect(hot.setPhase(0.0) == true && hot.pulse == 0.5)  // the pulse starts at the middle and peaks 0.3125 s in
        #expect(hot.setPhase(0.3125) && hot.pulse == 1.0)

        let card = makeCard()
        card.setLights(link: .warn, mic: .ok)
        card.setPhase(0.0)
        let lit = Bitmap(snap(card.header, scale: 2)).bytes
        card.setPhase(0.6)
        #expect(Bitmap(snap(card.header, scale: 2)).bytes != lit)  // and what is drawn really changes
    }

    @Test func theDotIsARingWhenUnknownOrOffAndSolidOtherwise() {
        func dot(_ state: LedState) -> Int {
            let card = makeCard()
            card.setLights(link: state, mic: .ok)
            return Bitmap(snap(card.header, scale: 2)).alpha(card.header.linkX + 7, 13, dpr: 2)
        }
        #expect(dot(.ok) > 200 && dot(.unknown) < 80 && dot(.off) < 80)  // empty in the middle
    }

    @Test func theHeaderShowsTheNameTheChipAndNothingOverlaps() {
        let card = makeCard(Themes.cyan.with { $0.botName = "pixel"; $0.modelChip = "gpt-5" })
        let h = card.header
        #expect(h.chip != nil && h.chip!.maxX <= h.bounds.width - 12)
        #expect(h.chip!.minX > h.micX + h.mic.width)
        #expect(h.chipText == "gpt-5" && h.displayName == "PIXEL")  // the name is upper-case
    }

    @Test func theChipDefaultsToTheConfiguredModelAndABlankOneHidesIt() {
        let card = makeCard(Themes.cyan, model: "claude-sonnet-5.5")
        #expect(card.header.chipText == "sonnet-5.5" && card.header.chip != nil)
        card.setTheme(Themes.cyan.with { $0.modelChip = "   " })
        #expect(card.header.chip == nil)
        card.setTheme(Themes.cyan)
        #expect(card.header.chip != nil)
    }

    @Test(arguments: ["ROBO", "WWWWWWWWWWWW", "iiiiiiiiiiii"], [(LedState.ok, LedState.ok), (.bad, .hot), (.unknown, .off)])
    func theChipGivesWayBeforeTheNameAndTheLights(_ name: String, _ states: (LedState, LedState)) {
        let card = makeCard(Themes.cyan.with { $0.botName = name; $0.modelChip = "a-very-long-model" })
        card.setLights(link: states.0, mic: states.1)
        let h = card.header
        #expect(h.micX + h.mic.width <= h.bounds.width - 12)  // the lights always fit
        if let chip = h.chip {  // else hidden, which is the fallback
            #expect(chip.width >= 40 && chip.minX >= h.micX + h.mic.width && chip.maxX <= h.bounds.width - 12)
        }
    }

    @Test func theHeaderTextIsPainted() {
        let card = makeCard()
        let img = Bitmap(snap(card.header, scale: 1))
        let row = (0..<328).map { img.at(Double($0), 13) }
        #expect(Set(row.map { "\($0.r),\($0.g),\($0.b),\($0.a)" }).count > 8)  // diamond, name, lights, chip
    }
}

// MARK: quote and labels

@Suite @MainActor struct CardQuoteTests {
    @Test func theQuoteHidesWhenThereIsNothingToQuote() {
        let card = makeCard()
        card.setHeard("what's due?", followUp: false)
        #expect(!card.quote.isHidden && card.quote.text.string == "what's due?" && card.quote.followUp.isHidden)
        card.setHeard("and Friday?", followUp: true)
        #expect(!card.quote.followUp.isHidden)
        card.setHeard("", followUp: true)  // the automatic digest: no user text, so no tag either
        #expect(card.quote.isHidden && card.quote.followUp.isHidden)
    }

    @Test func theQuoteIsAsTallAsItsTextUpToANinetyPixelCapThenScrolls() {
        let card = makeCard()
        card.setHeard("what is due", followUp: false)
        #expect(card.quote.text.frame.height == 17 && card.quote.height == 12 + 2 + 17 + 7)  // one line of 12 px italic, plus 2
        card.setHeard(String(repeating: "a very long question ", count: 40), followUp: false)
        #expect(card.quote.text.frame.height == CardView.heardMax && card.quote.text.overflows)
    }

    @Test func theQuotePaintsItsAccentBarAndAFadingHairline() {
        let quote = QuoteView(theme: Themes.cyan)
        quote.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        let img = Bitmap(snap(quote, scale: 2))
        let bar = img.at(0.5, 10, dpr: 2), want = Themes.accent(Themes.cyan, Themes.cyan.hue)  // the live accent
        #expect(abs(bar.r - Int(want.r)) < 30 && abs(bar.b - Int(want.b)) < 30)
        #expect(img.alpha(150, 59.5, dpr: 2) > 0)  // the hairline at the foot
        #expect(img.alpha(290, 59.5, dpr: 2) < 10)  // fades out to the right
    }

    @Test func aMicroLabelPaintsItselfInTheLabelColour() {
        let label = MicroLabel("YOU ▸", theme: Themes.cyan)
        #expect(label.text == "YOU ▸")
        label.text = "searching the web…"
        #expect(label.fitting.width > 60)
        label.frame = NSRect(origin: .zero, size: label.fitting)
        let img = Bitmap(snap(label, scale: 2)), want = Double(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).hueComponent)
        _ = want
        let target = Double(Themes.labelColour(Themes.cyan, Themes.cyan.hue).ns.hueComponent) * 360
        let found = (0..<img.width).contains { x in (0..<img.height).contains { y in img.at(Double(x), Double(y)).a > 250 && angle(img.hue(Double(x), Double(y)), target) < 12 } }
        #expect(found)
        let warn = MicroLabel("APPROVAL ▸", theme: Themes.cyan, tone: .warn)
        warn.frame = NSRect(origin: .zero, size: warn.fitting)
        let w = Bitmap(snap(warn, scale: 2)), warnHue = Double(Chrome.color(Themes.cyan.ledWarn).hueComponent) * 360
        #expect((0..<w.width).contains { x in (0..<w.height).contains { y in w.at(Double(x), Double(y)).a > 250 && angle(w.hue(Double(x), Double(y)), warnHue) < 12 } })
    }

    @Test func theStatusRowShowsTheDotsAndTheLabelOnlyWhileTheyAreOn() {
        let card = makeCard()
        var fits = 0
        card.fit = { fits += 1; $0() }
        card.setStatusRow(typing: false, label: "")
        #expect(fits == 0 && card.statusRow.isHidden)
        card.setStatusRow(typing: true, label: "searching the web…")
        #expect(fits == 1 && !card.statusRow.isHidden && card.statusRow.height == 16)
        card.setStatusRow(typing: true, label: "reading a page…")  // the same pair is no change
        #expect(fits == 1 && card.statusRow.label.text == "reading a page…")
        card.setStatusRow(typing: false, label: "listening")
        #expect(fits == 2 && card.statusRow.dots.isHidden && !card.statusRow.label.isHidden && card.statusRow.height == 15)
        card.setStatusRow(typing: false, label: "")
        #expect(fits == 3 && card.statusRow.isHidden)
        #expect(card.fittingHeight == 61)
    }
}

// MARK: the typing dots

@Suite @MainActor struct CardDotsTests {
    @Test func theDotsKeepTheirWave() {
        let a = TypingDotsView.offsets(0.0), b = TypingDotsView.offsets(0.2)
        #expect(a.count == 3 && a != b && (a + b).map { abs($0) }.max()! <= TypingDotsView.hop)
    }

    @Test func theDotsHopInTheAccentColourWithoutAPill() {
        let dots = TypingDotsView(theme: Themes.cyan)
        dots.clock = { 0 }
        #expect(dots.frame.size == NSSize(width: 32, height: 16))
        let img = Bitmap(snap(dots, scale: 2)), want = Themes.accent(Themes.cyan, Themes.cyan.hue)
        #expect(img.alpha(31, 8, dpr: 2) == 0 && img.alpha(0, 15, dpr: 2) == 0)  // no pill
        let first = img.straight(5, 8, dpr: 2)  // the first dot's column: always inside its dot
        #expect(first.a > 100 && first.b > first.r && abs(first.g - Int(want.g)) < 40)
    }

    @Test(arguments: keys) func theDotsTakeTheThemeAndTheLiveHue(_ key: String) {
        let t = Themes.all.first { $0.key == key }!
        let dots = TypingDotsView(theme: t)
        dots.clock = { 0 }
        dots.theme = t; dots.hue = 356  // an error: red whatever the theme
        let p = Bitmap(snap(dots, scale: 2)).at(5, 8, dpr: 2)
        #expect(p.r > p.g && p.r > p.b)
        dots.hue = t.hue
        #expect(dots.hue == t.hue)
    }

    @Test func theDotsOwnATimerOnlyWhileTheyAreShown() {
        let card = makeCard()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200), styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = card
        #expect(!(card.statusRow.dots.timer != nil))  // hidden: no timer
        card.setStatusRow(typing: true, label: "")
        #expect((card.statusRow.dots.timer != nil))
        card.setStatusRow(typing: false, label: "listening")
        #expect(!(card.statusRow.dots.timer != nil))
        card.setStatusRow(typing: true, label: "")
        #expect((card.statusRow.dots.timer != nil))
        card.setStatusRow(typing: false, label: "")
        #expect(!(card.statusRow.dots.timer != nil))
        window.contentView = nil
    }
}

// MARK: the caret

@Suite @MainActor struct CardCaretTests {
    @Test(arguments: keys) func theCaretSitsInsideTheViewportAtTheEndOfTheText(_ key: String) {
        let t = Themes.all.first { $0.key == key }!
        let card = makeCard(t)
        card.setReply(markdown: String(repeating: "Friday has the **lab report** due and a meeting with the professor. ", count: 6), hiddenTail: 0)
        card.reply.scrollValue = card.reply.scrollMaximum
        let line = card.reply.cursorRect(at: card.reply.length)
        #expect(line.minY >= 0 && line.maxY <= card.reply.frame.height + 1)  // scrolled to the end: the last line is in view
        let viewport = card.reply.contentView.bounds
        let box = CaretView.box(for: line, theme: t, in: viewport.size)
        #expect(viewport.contains(box))
        let px = CGFloat(t.textPx)
        #expect(abs(box.width - 2 - px * 0.58) <= 1.5 && abs(box.height - 2 - px * 1.18) <= 1.5)
        #expect(abs(box.midY - line.midY) <= 3)  // on the text line
        #expect(box.minX >= line.minX - 1)  // at the cursor, not before it
        #expect(card.caret.frame.minX >= card.reply.frame.minX && card.reply.frame.contains(card.caret.frame))
    }

    @Test func theCaretIsKeptInsideEvenWhenTheLineIsNotVisibleYet() {
        let size = CGSize(width: 302, height: 120)
        for line in [CGRect(x: 5000, y: 9000, width: 1, height: 16), CGRect(x: -50, y: -90, width: 1, height: 16), CGRect(x: 299, y: 119, width: 1, height: 16)] {
            #expect(CGRect(origin: .zero, size: size).contains(CaretView.box(for: line, theme: Themes.cyan, in: size)), "\(line)")
        }
    }

    @Test(arguments: ["block", "bar", "under"]) func theCaretIsABlockABarOrAnUnderline(_ style: String) {
        let t = Themes.cyan.with { $0.caret = style }
        let box = CaretView.box(for: CGRect(x: 10, y: 20, width: 1, height: 17), theme: t, in: CGSize(width: 302, height: 120))
        let caret = CaretView(theme: t)
        caret.frame = CGRect(origin: .zero, size: box.size)
        let w = Int(box.width), h = Int(box.height)
        func marks(_ c: CaretView) -> [Bool] {
            let img = Bitmap(snap(c, scale: 1))
            return [(w / 2, h / 2), (2, h / 2), (w / 2, h - 3)].map { img.alpha(Double($0.0), Double($0.1)) > 200 }
        }
        #expect(marks(caret) == ["block": [true, true, true], "bar": [false, true, false], "under": [false, false, true]][style]!)
        caret.setOn(false)  // the dark half of a blink: none of the three marks is painted
        #expect(marks(caret) == [false, false, false])
    }

    @Test func theCaretTakesNoClicks() { #expect(CaretView(theme: Themes.cyan).hitTest(NSPoint(x: 1, y: 1)) == nil) }

    @Test func theCaretShowsAndBlinksOnRequest() {
        let card = makeCard()
        #expect(card.caret.isHidden)
        card.setCaret(show: true, on: true)
        #expect(!card.caret.isHidden && card.caret.on)
        card.setCaret(show: true, on: false)
        #expect(!card.caret.isHidden && !card.caret.on)
        card.setCaret(show: false, on: true)
        #expect(card.caret.isHidden)
    }

    @Test func theCaretFollowsTheLastLetterShownAndNotTheHiddenWord() {
        let card = makeCard()
        card.setReply(markdown: "Hello wonderful world", hiddenTail: 15)  // "Hello " is on screen, the rest laid out but invisible
        let at6 = card.caret.frame.minX
        card.setReply(markdown: "Hello wonderful world", hiddenTail: 5)
        #expect(card.caret.frame.minX > at6)
        #expect(card.reply.string == "Hello wonderful world")
    }
}

// MARK: the picker and the menu

@Suite @MainActor struct CardMenuTests {
    @Test func thePickerHasFiveSwatchesAndSaysWhichThemeIsCurrent() {
        let card = makeCard(Themes.matrix)
        #expect(card.picker.swatches.map(\.key) == keys && keys.count == 5)
        #expect(card.picker.label.text == "THEME ▸ MATRIX")
        #expect(card.picker.swatches.map(\.view.current) == keys.map { $0 == "matrix" })
        card.setTheme(Themes.amber)
        #expect(card.picker.label.text == "THEME ▸ AMBER CRT")
        #expect(card.picker.swatches.filter(\.view.current).map(\.key) == ["amber"])
        #expect(card.picker.subviews.count == 6)  // the label and one swatch each
    }

    @Test func aClickOnASwatchSaysWhichThemeWasPicked() {
        let card = makeCard()
        var got: [String] = []
        card.onPickTheme = { got.append($0) }
        card.picker.swatches.first { $0.key == "aurora" }!.view.onClick?()
        card.picker.swatches.first { $0.key == "daylight" }!.view.onClick?()
        #expect(got == ["aurora", "daylight"])
    }

    @Test func swatchesAreMiniatureCardsInTheirOwnColours() {
        var shots: [[UInt8]] = []
        for t in Themes.all {
            let s = SwatchView(t)
            #expect(s.frame.size == NSSize(width: 54, height: 34) && s.toolTip == t.label && s.accessibilityLabel() == t.label)
            let img = Bitmap(snap(s))
            shots.append(img.bytes)
            let px = img.at(45, 8), want = Themes.rgba(t.bgTop)  // the card's own glass, top right
            #expect(abs(px.r - Int(want.r)) < 30 && abs(px.b - Int(want.b)) < 30, "\(t.key)")
            let dot = img.at(54 - 10, 34 - 9), a = Themes.accent(t, t.hue)  // the accent dot at the bottom right
            #expect(abs(dot.r - Int(a.r)) < 40 && abs(dot.g - Int(a.g)) < 40, "\(t.key)")
        }
        #expect(Set(shots).count == 5)
    }

    @Test func theCurrentSwatchIsRinged() {
        let s = SwatchView(Themes.matrix)
        let plain = Bitmap(snap(s))
        s.current = true
        let ringed = Bitmap(snap(s))
        #expect(plain.bytes != ringed.bytes)
        #expect(ringed.alpha(2, 17) > 200 && ringed.at(2, 17).g > plain.at(2, 17).g)  // the stroke on the left edge
    }

    @Test func theMenuIsThreeByTwoAndWithoutAWatcherThemeAndQuitTakeThreeEach() {
        func grid(_ card: CardView) -> [String: [Int]] {
            Dictionary(uniqueKeysWithValues: card.chips.cells.map { ($0.0.title.split(separator: " ").last.map(String.init)!, [$0.1, $0.2, $0.3]) })
        }
        #expect(grid(makeCard()) == ["Digest": [0, 0, 2], "Type": [0, 2, 2], "Stay": [0, 4, 2], "Theme": [1, 0, 3], "Quit": [1, 3, 3]])  // row, column, columns
        let watched = grid(makeCard(watch: true))
        #expect(watched["Watch"] == [1, 0, 2] && watched["Theme"] == [1, 2, 2] && watched["Quit"] == [1, 4, 2] && watched.count == 6)
    }

    @Test func theMenuChipsFillTheColumnInSixEqualColumns() {
        let card = makeCard(watch: true)
        card.showMenu(stay: "📌 Stay", watch: "⏸ Watch")
        let rects = card.chips.buttons.map { $0.frame }
        #expect(rects.map(\.width) == [97, 96, 97, 97, 96, 97] && rects.map(\.minY) == [0, 0, 0, 34, 34, 34])
        #expect(rects[0].minX == 0 && rects[2].maxX == 302 && rects[1].minX - rects[0].maxX == 6)
        let bare = makeCard()
        bare.showMenu(stay: "📌 Stay", watch: "⏸ Watch")
        #expect(bare.chips.watch.isHidden && bare.chips.themer.frame.width == 148 && bare.chips.quit.frame.maxX == 302)
    }

    @Test func theThemeChipOpensTheSwatchesAndTheMenuStaysOpen() {
        let card = makeCard()
        var themed = 0
        card.onTheme = { themed += 1 }
        card.showMenu(stay: "📌 Stay", watch: "⏸ Watch")
        #expect(card.picker.isHidden && card.chips.themer.title == "🎨 Theme")
        card.chips.themer.onClick?()
        #expect(!card.picker.isHidden && !card.chips.isHidden && themed == 1)  // the menu did not close
        #expect(card.bounds.contains(card.picker.frame.offsetBy(dx: 0, dy: 0)) || card.fittingHeight >= card.picker.frame.maxY + 19)
        #expect(card.picker.label.text == "THEME ▸ CYAN HUD")
        card.chips.themer.onClick?()
        #expect(card.picker.isHidden)
        card.chips.themer.onClick?()
        card.hideMenu()  // closing the menu takes the swatches with it
        #expect(card.picker.isHidden && card.chips.isHidden)
    }

    @Test func aMenuEntryHidesTheMenuBeforeItIsReported() {
        let card = makeCard()
        var got: [(MenuAction, Bool)] = []
        card.onMenu = { got.append(($0, card.chips.isHidden && card.picker.isHidden)) }
        card.showMenu(stay: "🧭 Wander", watch: "▶ Watch")
        #expect(card.chips.stay.title == "🧭 Wander")
        card.togglePicker()
        card.chips.stay.onClick?()
        card.showMenu(stay: "📌 Stay", watch: "⏸ Watch")
        card.chips.digest.onClick?(); card.chips.type.onClick?(); card.chips.quit.onClick?()
        #expect(got.map(\.0) == [.stay, .digest, .type, .quit] && got.allSatisfy(\.1))
    }

    @Test func buttonsAreButtonsForAccessibilityAndClickWhenReleasedInside() {
        let card = makeCard(watch: true)
        #expect(card.chips.digest.accessibilityRole() == .button && card.chips.digest.accessibilityLabel() == "📚 Digest")
        var clicks = 0
        card.chips.digest.onClick = { clicks += 1 }
        _ = card.chips.digest.accessibilityPerformPress()
        #expect(clicks == 1)
    }

    @Test func theFitCallbackWrapsEveryChangeOfHeight() {
        let card = makeCard()
        var fits = 0, heights: [CGFloat] = []
        card.fit = { change in fits += 1; change(); heights.append(card.fittingHeight) }
        card.showMenu(stay: "📌 Stay", watch: "⏸ Watch")
        card.togglePicker()
        card.setApproval("ok?")
        card.setApproval(nil)
        card.hideMenu()
        card.hideMenu()  // already hidden: nothing to fit
        #expect(fits == 5 && heights.first == 42 + 62 + 19 && heights.last == 61)
    }
}

// MARK: approval and footer

@Suite @MainActor struct CardApprovalTests {
    @Test func theApprovalShowsTheRequestAndReportsAllowAndDeny() {
        let card = makeCard()
        var choices: [String] = []
        card.onApprove = { choices.append($0) }
        card.setApproval("Run: ls -la")
        #expect(!card.approval.isHidden && card.approval.well.text == "Run: ls -la" && card.approval.label.text == "APPROVAL ▸")
        card.approval.allow.onClick?(); card.approval.deny.onClick?()
        #expect(choices == ["once", "deny"])
        card.setApproval(nil)
        #expect(card.approval.isHidden)
    }

    @Test func theApprovalGrowsWithItsWrappedText() {
        let card = makeCard()
        card.setApproval("ls")
        let short = card.fittingHeight
        card.setApproval(String(repeating: "word ", count: 60))
        #expect(card.fittingHeight > short + 28)
        let a = card.approval
        #expect(card.fittingHeight == 42 + a.height(for: 302) + 19 && a.frame.height == a.height(for: 302))
        #expect(a.allow.frame.maxY == a.frame.height && a.allow.frame.width == 147 && a.deny.frame.minX == 155)
    }

    @Test func theFooterIsStoredNotShownUntilTheTypingIsDone() {
        let card = makeCard()
        card.setFooter("📓 In Obsidian: Plan")
        #expect(card.footer.isHidden && card.fittingHeight == 61)
        card.showFooter()
        #expect(!card.footer.isHidden && card.footer.text == "📓 In Obsidian: Plan" && card.fittingHeight >= 81)
        card.clearReply()
        #expect(card.footer.isHidden && card.footer.text == "")
        card.setFooter("")
        card.showFooter()
        #expect(card.footer.isHidden)  // nothing to show
    }

    @Test func aWrappedFooterCountsInTheHeight() {
        let card = makeCard()
        card.setFooter("one\ntwo\nthree")
        card.showFooter()
        #expect(card.footer.frame.height == card.footer.height(for: 302) && card.footer.height(for: 302) >= 7 + 3 * 13)
    }
}

// MARK: the reply

@Suite @MainActor struct CardReplyTests {
    @Test func theReplyBoxIsAsTallAsItsTextPlusTwoAndHiddenWhenEmpty() {
        let card = makeCard()
        card.setReply(markdown: "", hiddenTail: 0)
        #expect(card.reply.isHidden && card.reply.frame.height == 0 && card.fittingHeight == 61)
        card.setReply(markdown: "Hello there", hiddenTail: 0)
        #expect(!card.reply.isHidden && card.reply.frame.height == CGFloat(Int(card.reply.documentHeight)) + 2)
        #expect(card.fittingHeight == 42 + card.reply.frame.height + 19)
        card.clearReply()
        #expect(card.reply.isHidden && card.reply.frame.height == 0 && card.caret.isHidden)
    }

    @Test func aLongReplyScrollsPastTheCapAndFollowsTheEndUnlessTheReaderScrolledUp() {
        let card = makeCard()
        card.setReply(markdown: longReply, hiddenTail: 0)
        let bar = card.reply
        #expect(bar.frame.height == CardView.textMax && bar.overflows && bar.scrollMaximum > 40)
        #expect(bar.scrollValue >= bar.scrollMaximum - 4)  // follows the last letter
        card.setFrameSize(NSSize(width: 340, height: card.fittingHeight)); card.relayout()  // placing the card again keeps the place
        #expect(bar.scrollValue >= bar.scrollMaximum - 4)
        _ = snap(card)  // and so does drawing it (the scroll view tiles itself on the first draw)
        #expect(bar.scrollValue >= bar.scrollMaximum - 4, "after drawing: \(bar.scrollValue) of \(bar.scrollMaximum)")
        let mid = (bar.scrollMaximum / 2).rounded()
        bar.scrollValue = mid  // the reader goes back, not to the very top: replacing the text resets to 0
        card.setReply(markdown: longReply + "\n\nand more", hiddenTail: 0)
        #expect(bar.scrollValue == mid && bar.scrollMaximum > 2 * mid)  // still reading the same lines
        #expect(bar.frame.contains(card.caret.frame))  // kept inside the box, though the end of the text is scrolled out of view
        bar.scrollValue = bar.scrollMaximum - 3  // within 4 pt of the end counts as at the end
        card.setReply(markdown: longReply + "\n\nand more and more\n\nand more", hiddenTail: 0)
        #expect(bar.scrollValue >= bar.scrollMaximum - 4)
    }

    @Test func aFirstReplyAfterAnEmptyQuoteStillFollowsTheEnd() {
        let card = makeCard()  // as the window starts an exchange: the quote and the footer are cleared, then the reply comes
        card.setHeard("", followUp: false)
        card.setFooter("")
        card.setReply(markdown: longReply, hiddenTail: 0)
        card.showFooter()
        #expect(card.reply.scrollMaximum > 0 && card.reply.scrollValue >= card.reply.scrollMaximum - 4)
    }

    @Test func theStatusLabelHasRoomForEveryTextItIsGiven() {
        let card = makeCard()
        card.setStatusRow(typing: true, label: "browsing…")
        for label in ["using computer_use…", "searching the web…", "ok"] {
            card.setStatusRow(typing: true, label: label)
            #expect(card.statusRow.label.frame.width >= card.statusRow.label.fitting.width, "\(label)")
        }
        card.setStatusRow(typing: false, label: "listening")  // the dots go, the label moves to the left edge
        #expect(card.statusRow.label.frame.minX == 0 && card.statusRow.label.frame.width >= card.statusRow.label.fitting.width)
    }

    /// A reply that overflows is laid out at the width with the scroll bar on every tick, not at both widths: the typing tick of a
    /// 16k reply cost twice as much for it.
    @Test func aTallReplyIsNotLaidOutAtTheOtherWidthOnEveryTick() {
        let card = makeCard()
        let text = (0..<200).map { "Paragraph \($0) with a few words in it." }.joined(separator: "\n\n")
        card.setReply(markdown: String(text.prefix(2_000)), hiddenTail: 4)
        #expect(card.reply.overflows)
        let before = card.reply.widthChanges
        for n in stride(from: 2_004, through: 2_400, by: 4) { card.setReply(markdown: String(text.prefix(n)), hiddenTail: 4) }
        #expect(card.reply.widthChanges == before)
        card.setReply(markdown: "short", hiddenTail: 0)  // and it goes back to the full width when the text is short again
        #expect(!card.reply.overflows && card.reply.textView.frame.width == 302)
    }

    @Test func keepingTheWidthDecidesLikeMeasuringAgainAtEveryTick() {
        let words = (0..<400).map { "word\($0 % 17)" }
        for cap in [90.0, 300.0] {
            let kept = TextBox(width: 302)
            var sizes = Array(stride(from: 1, through: 400, by: 7)); sizes += sizes.reversed()  // growing, then shrinking
            for n in sizes {
                let md = words.prefix(n).joined(separator: " ")
                kept.setContent(Markdown.attributed(md, theme: Themes.cyan))
                let fresh = TextBox(width: 302)
                fresh.setContent(Markdown.attributed(md, theme: Themes.cyan))
                let a = kept.wantedHeight(cap: cap), b = fresh.wantedHeight(cap: cap)
                #expect(a == b && kept.overflows == fresh.overflows, "\(n) words, cap \(cap): kept \(a) \(kept.overflows), fresh \(b) \(fresh.overflows)")
            }
        }
    }

    @Test func aSlowRenderMakesTheNextOnesWaitAndTheLatestTextStillArrives() {
        let card = makeCard()
        var clock = 100.0
        card.now = { clock }
        card.renderBudget = -1  // every render counts as slow
        card.setReply(markdown: "one", hiddenTail: 0)
        #expect(card.reply.string == "one")
        clock += 0.04
        card.setReply(markdown: "one two", hiddenTail: 0)
        clock += 0.04
        card.setReply(markdown: "one two three", hiddenTail: 0)
        #expect(card.reply.string == "one")  // skipped: 100 ms have not passed
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        #expect(card.reply.string == "one two three")  // the last text is rendered when the wait is over
        clock += 1
        card.setReply(markdown: "four", hiddenTail: 0)
        #expect(card.reply.string == "four")  // after the wait a render is immediate again
    }

    @Test func aCheapRenderIsNeverSkipped() {
        let card = makeCard()
        card.renderBudget = 10
        for n in 1...20 {
            card.setReply(markdown: (1...n).map(String.init).joined(separator: " "), hiddenTail: 0)
            #expect(card.reply.string.hasSuffix(" \(n)") || n == 1)  // the text of every call is on screen at once
        }
    }

    @Test func aNewExchangeAndANewThemeDropTheWait() {
        let card = makeCard()
        let clock = 100.0
        card.now = { clock }
        card.renderBudget = -1
        card.setReply(markdown: "one", hiddenTail: 0)
        card.setReply(markdown: "one two", hiddenTail: 0)  // waiting
        card.clearReply()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        #expect(card.reply.string == "")  // what was waiting belongs to the old exchange
        card.setReply(markdown: "fresh", hiddenTail: 0)
        card.setTheme(Themes.matrix)  // the window renders again at once in the new look
        card.setReply(markdown: "fresh again", hiddenTail: 0)
        #expect(card.reply.string == "fresh again")
    }

    @Test func theScrollBarTakesFivePixelsOfWidthAndWrapsTheTextAgain() {
        let card = makeCard()
        card.setReply(markdown: "short", hiddenTail: 0)
        #expect(!card.reply.overflows && card.reply.textView.frame.width == 302)
        card.setReply(markdown: longReply, hiddenTail: 0)
        #expect(card.reply.overflows && card.reply.textView.frame.width == 297)
    }

    @Test func theHiddenWordIsLaidOutSoAWordThatWontFitWrapsEarly() {
        let card = makeCard()
        let word = String(repeating: "w", count: 60)
        card.setReply(markdown: "Hello \(word)", hiddenTail: 60)
        let hidden = card.reply.frame.height
        card.setReply(markdown: "Hello", hiddenTail: 0)
        #expect(hidden > card.reply.frame.height)  // the invisible word already took its own line
    }

    @Test func aReplyInTheCardPaintsItsTextAndItsCodeBox() {
        let card = makeCard()
        card.setReply(markdown: "plain\n\n```\ncode\n```", hiddenTail: 0)
        card.setFrameSize(NSSize(width: 340, height: card.fittingHeight))
        card.relayout()
        let img = Bitmap(snap(card, scale: 1))
        let box = img.at(160, card.reply.frame.maxY - 8)  // inside the code box, right of the text
        let want = Themes.rgba(card.theme.codeBg)
        #expect(abs(box.r - Int(want.r)) < 12 && abs(box.b - Int(want.b)) < 12)
    }

    @Test func aClickOnTheReplySkipsOnlyWhenItIsAPlainClick() {
        let card = makeCard()
        var skips = 0
        card.onReplyClick = { skips += 1 }
        card.setReply(markdown: "[notes](https://example.invalid/x) and then a long tail of words", hiddenTail: 0)
        let view = card.reply.textView
        view.click(from: NSPoint(x: 150, y: 8), to: NSPoint(x: 152, y: 9))
        #expect(skips == 1)
        view.click(from: NSPoint(x: 150, y: 8), to: NSPoint(x: 250, y: 8))  // a drag
        view.click(from: NSPoint(x: 150, y: 8), to: NSPoint(x: 150, y: 12))  // 4 px away is no click either
        #expect(skips == 1)
        let spot = card.reply.contentView.convert(card.reply.cursorRect(at: 2), to: view)  // on the letters of the link
        let on = NSPoint(x: spot.midX + 3, y: spot.midY)
        #expect(view.isLink(at: on) && !view.isLink(at: NSPoint(x: 250, y: 8)))
        view.click(from: on, to: on)
        #expect(skips == 1)
        view.setSelectedRange(NSRange(location: 20, length: 5))  // a selection
        view.click(from: NSPoint(x: 150, y: 8), to: NSPoint(x: 150, y: 8))
        #expect(skips == 1)
    }

    @Test(arguments: ["http://example.com/a", "https://example.com/a?x=1", "mailto:a@b.c", "HTTPS://EXAMPLE.COM/UP"])
    func aLinkToTheWebOrMailOpensInTheDefaultBrowser(_ link: String) {
        let card = makeCard()
        var opened: [URL] = []
        card.reply.textView.openLink = { opened.append($0) }
        card.setReply(markdown: "see [the notes](\(link))", hiddenTail: 0)
        card.reply.textView.clicked(onLink: URL(string: link)!, at: 5)
        #expect(opened == [URL(string: link)!])
        #expect(card.reply.string == "see the notes")  // the link is not typed into the text
    }

    /// The reply is a model's text built from mail, Teams and Moodle: a link in it may not open a file, a share or an app.
    @Test(arguments: ["file:///etc/passwd", "smb://host/share", "javascript:alert(1)", "robo://x", "ftp://host/f", "x-apple.systempreferences:com.apple.preference.security",
                      "tel:123", "data:text/html,hi", "/relative/path", "example.com", "vnc://host", "FILE:///Users"])
    func aLinkToAnythingElseDoesNothing(_ link: String) {
        let card = makeCard()
        var opened: [URL] = []
        card.reply.textView.openLink = { opened.append($0) }
        card.reply.textView.clicked(onLink: URL(string: link)!, at: 0)
        card.reply.textView.clicked(onLink: link, at: 0)  // the link can come as a string too
        #expect(opened.isEmpty)
    }

    @Test func theReplyIsSelectableButNeverEditable() {
        let card = makeCard()
        #expect(card.reply.textView.isSelectable && !card.reply.textView.isEditable)
        #expect(card.reply.textView.acceptsFirstMouse(for: nil))  // a click in a window that is not key still works
    }

    /// CLAUDE.md: a typing tick costs about 3 ms in Qt (`setMarkdown`), 30 times a second for a few seconds.
    @Test func aTypingStepIsCheap() {
        let card = makeCard(Themes.matrix)
        let reply = String(repeating: "## This week\n\n- *Linear Algebra* set - due Thursday\n- Physics lab report\n\nThe chain rule: `d/dx f(g(x))`.\n\n```python\ndef chain(f, g, x):\n    return f(g(x))\n```\n\nSee [the notes](https://example.com/notes).\n\n", count: 7)
        #expect(reply.count > 1400 && reply.count < 1700)
        var best = 1.0
        for k in 0..<20 {
            let t = ProcessInfo.processInfo.systemUptime
            card.setReply(markdown: reply + String(repeating: "x", count: k), hiddenTail: 4)
            best = min(best, ProcessInfo.processInfo.systemUptime - t)
        }
        #expect(best < 0.03, "a step took \(best * 1000) ms")  // Qt's 3 ms, with room for a debug build
        print("setReply of \(reply.count) characters: \(best * 1000) ms")
    }

    @Test func isUnderMouseIsFalseWithoutAWindow() { #expect(!makeCard().isUnderMouse) }
}

// MARK: a live theme switch is the same as a fresh build

@Suite @MainActor struct CardThemeSwitchTests {
    private let md = "## Plan\n\nYou have **three** things due: *lab*, `CS 240` and [the notes](https://x.io).\n\n- one\n- two\n\n```python\nx = 1\n```\n\nDone."

    private func filled(_ t: Theme) -> CardView {
        let card = makeCard(t)
        card.setHeard("What's due this week?", followUp: true)
        card.setFooter("📓 In Obsidian: Plan")
        card.setReply(markdown: md, hiddenTail: 0)
        card.showFooter()
        card.setLights(link: .ok, mic: .ok)
        card.setHue(t.hue)
        card.setFrameSize(NSSize(width: 340, height: card.fittingHeight))
        card.relayout()
        return card
    }

    @Test(arguments: [("cyan", "matrix"), ("aurora", "daylight"), ("daylight", "amber")])
    func switchingThemeLivePaintsWhatAFreshBuildPaints(_ src: String, _ dst: String) {
        let from = Themes.all.first { $0.key == src }!, to = Themes.all.first { $0.key == dst }!
        let live = filled(from)
        live.setTheme(to)
        live.setHue(to.hue)  // what the window does as the face settles on the new theme's hue
        live.setReply(markdown: md, hiddenTail: 0)  // and renders the reply again
        live.setFrameSize(NSSize(width: 340, height: live.fittingHeight))
        live.relayout()
        let fresh = filled(to)
        #expect(live.frame.size == fresh.frame.size)
        let a = Bitmap(snap(live, scale: 2)).bytes, b = Bitmap(snap(fresh, scale: 2)).bytes
        #expect(a.count == b.count)
        let mean = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        #expect(mean < 0.5, "\(src) -> \(dst): \(mean)")  // of 255
    }
}
