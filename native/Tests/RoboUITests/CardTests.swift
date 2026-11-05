// The Liquid Glass card: the glass pane and its tint,
// the header and its lights, the quote, the caret, the menu grid, the approval, the sizing and scrolling of the reply, the
// skip click. The card paints no frame of its own any more (the pane is a system view behind it), so what is checked here is
// its geometry, its tint, and that everything else it draws is the small marks on top.
// Colours that the system decides (label, separator, fills) follow light and dark, so a pixel probe on them asserts "painted /
// not painted / differs".
import AppKit
import Foundation
import Testing
@testable import RoboCore
@testable import RoboUI

// MARK: helpers

@MainActor private func makeCard(_ t: Theme = Themes.glass, watch: Bool = false) -> CardView {
    _ = NSApplication.shared
    Chrome.ink = nil  // a test that gave the card an ink must not colour the next one
    let card = CardView(theme: t, hasWatch: watch)
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
    /// Every pixel (x, y) in image pixels, with its colour un-premultiplied.
    var pixels: [(x: Int, y: Int, r: Int, g: Int, b: Int, a: Int)] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                let i = (y * width + x) * 4, a = Double(max(1, Int(data[i + 3]))) / 255
                return (x, y, Int(Double(data[i]) / a), Int(Double(data[i + 1]) / a), Int(Double(data[i + 2]) / a), Int(data[i + 3]))
            }
        }
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

/// A card is fitted to what it shows, as the window does after a change.
@MainActor private func fitted(_ card: CardView) {
    card.setFrameSize(NSSize(width: CardView.width, height: card.fittingHeight))
    card.relayout()
}

/// sRGB components of a colour, to compare two NSColors that are not the same object.
private func components(_ c: NSColor?) -> [CGFloat] {
    guard let s = c?.usingColorSpace(.sRGB) else { return [] }
    return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent]
}

private func same(_ a: NSColor?, _ b: NSColor) -> Bool {
    let x = components(a), y = components(b)
    return x.count == 4 && zip(x, y).allSatisfy { abs($0 - $1) < 0.01 }
}

private let hues = [0.0, 90, 188, 270, 330]

private let longReply = (0..<24).map { "Paragraph \($0) with a few words in it." }.joined(separator: "\n\n")

// MARK: the glass pane

@Suite @MainActor struct CardFrameTests {
    @Test func theCardIsAsWideAsTheOldPanelAndPutsTheHeaderInTheFrame() {
        let card = makeCard()
        #expect(card.frame.width == CardView.width && CardView.width == 340)
        #expect(card.header.frame == NSRect(x: 6, y: 6, width: 328, height: 26))  // inside the 6 px glass margin
        card.setFrameSize(NSSize(width: 340, height: 330))
        #expect(card.header.frame == NSRect(x: 6, y: 6, width: 328, height: 26))
        #expect(card.isFlipped)
    }

    @Test func theColumnHasItsMarginsAndSpacingAndHiddenItemsTakeNoRoom() {
        let card = makeCard()
        #expect(card.fittingHeight == 61.0)  // nothing shows: the top margin 42 and the bottom 19
        card.showMenu()
        #expect(card.fittingHeight == 123.0)  // 42 + 62 (two rows of 28 and 6 between) + 19: one item, so no spacing
        #expect(card.chips.frame == NSRect(x: 19, y: 42, width: 302, height: 62))
        card.setStatusRow(typing: true, label: "")
        #expect(card.fittingHeight == 123.0 + 8 + 16)  // the status row (16) under the menu with the column's 8
        #expect(card.statusRow.frame == NSRect(x: 19, y: 42 + 62 + 8, width: 302, height: 16))
        card.setStatusRow(typing: false, label: "")
        card.hideMenu()
        #expect(card.fittingHeight == 61)
    }

    @Test func theGlassPaneSitsInsideTheMarginsAndShortOfTheBottomByTheGap() {
        let card = makeCard()
        fitted(card)
        #expect(card.glass.frame == NSRect(x: 6, y: 6, width: 340 - 12, height: card.frame.height - 6 - 9))
        card.showMenu()  // taller card: the pane follows
        #expect(card.fittingHeight == 123)
        card.setFrameSize(NSSize(width: 340, height: card.fittingHeight))
        #expect(card.glass.frame == NSRect(x: 6, y: 6, width: 328, height: 123 - 15))
        #expect(card.glass.isFlipped)
    }

    @Test func theGlassIsTheFirstSubviewBehindEverythingTheCardDraws() {
        let card = makeCard()
        #expect(card.subviews.first === card.glass)
        let others = card.subviews.dropFirst()
        #expect(others.count == 9 && !others.contains { $0 === card.glass })
        let order = { (v: NSView) in card.subviews.firstIndex { $0 === v }! }
        for column in [card.chips, card.quote, card.statusRow, card.reply, card.footer, card.approval, card.nudge, card.caret] as [NSView] {
            #expect(order(card.header) > order(column) && order(column) > order(card.glass))
        }
    }

    @Test func theGlassIsTheSystemsGlass() {
        #expect(makeCard().glass.subviews.prefix(2).allSatisfy { $0 is NSGlassEffectView })
    }

    @Test func theCardDrawsNothingItselfOnlyTheMarksOnTheGlass() {
        let card = makeCard()
        #expect(!card.isOpaque)
        card.glass.isHidden = true
        let img = Bitmap(snap(card))
        #expect(img.alpha(5, 5) == 0 && img.alpha(339, 199) == 0)
        #expect(img.alpha(170, 195) == 0 && img.alpha(6, 195) == 0 && img.alpha(333, 195) == 0)  // the gap strip under the pane
        let header = NSRect(x: 6, y: 6, width: 328, height: 26)  // the only thing showing is the header
        let outside = img.pixels.filter { !header.contains(NSPoint(x: Double($0.x) + 0.5, y: Double($0.y) + 0.5)) && $0.a > 0 }
        #expect(outside.isEmpty, "\(outside.count) pixels outside the header, first at \(outside.first.map { "\($0.x),\($0.y)" } ?? "")")
        card.header.isHidden = true
        #expect(Bitmap(snap(card)).pixels.allSatisfy { $0.a == 0 })
    }
}

// MARK: the shade: what the card does about its backdrop

@Suite @MainActor struct CardShadeTests {
    /// The (white, alpha) of the colour an attributed string carries at `at`.
    private func carried(_ box: TextBox, _ at: Int) -> (white: CGFloat, alpha: CGFloat) {
        let c = components(box.textView.textStorage!.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)
        return (c[0], c[3])
    }

    @Test func withoutAShadeTheColoursAreTheSystemsOwn() {
        Chrome.ink = nil
        #expect(Chrome.text.isEqual(NSColor.labelColor) && Chrome.hairline.isEqual(NSColor.separatorColor))
        #expect(same(Chrome.wash(0.07), NSColor.labelColor.withAlphaComponent(0.07)))
    }

    @Test(arguments: [0.0, 0.25, 0.5, 1.0]) func theInkRunsFromNearWhiteToNearBlackWithTheSystemsAlphas(_ ink: Double) {
        defer { Chrome.ink = nil }
        Chrome.ink = ink
        let white = 0.96 + (0.07 - 0.96) * ink
        for (colour, alpha) in [(Chrome.text, 1.0), (Chrome.textDim, Chrome.dimAlpha), (Chrome.hairline, 0.18), (Chrome.wash(0.08), 0.08)] {
            let c = components(colour)
            #expect(c.count == 4 && c[0...2].allSatisfy { abs($0 - white) < 0.005 } && abs(c[3] - alpha) < 0.005, "ink \(ink): \(c)")
        }
    }

    /// Ink 1 = dark ink on a light card, 0 = light ink on a dark one; the glass is hidden (as in the other pixel tests) so only what the
    /// card draws itself is looked at.
    @Test(arguments: [0.0, 1.0]) func theReplyAndTheHairlineAreDrawnInTheInk(_ ink: Double) {
        defer { Chrome.ink = nil }
        let card = makeCard()
        card.setReply(markdown: "Hello **there** friend, MMMM", hiddenTail: 0)
        card.setShade(level: 1 - ink, ink: ink)
        fitted(card)
        card.glass.isHidden = true
        let want = Int((0.96 + (0.07 - 0.96) * ink) * 255 + 0.5)
        let box = card.reply.frame
        let letters = Bitmap(snap(card, scale: 2)).pixels.filter {
            $0.a > 240 && (box.minX * 2..<box.maxX * 2).contains(Double($0.x)) && (box.minY * 2..<box.maxY * 2).contains(Double($0.y))
        }
        #expect(!letters.isEmpty)
        #expect(letters.allSatisfy { abs($0.r - want) < 8 && abs($0.g - want) < 8 && abs($0.b - want) < 8 }, "want \(want), first \(letters.first.map { "\($0.r),\($0.g),\($0.b)" } ?? "")")
        let line = Bitmap(snap(card.header, scale: 2)).straight(100, 25.5, dpr: 2)  // the hairline under the header: 18 % ink
        #expect(abs(line.a - 46) < 6 && abs(line.r - want) < 14 && abs(line.b - want) < 14, "\(line)")
    }

    @Test func theTextIsBuiltAgainInTheNewInkOnlyWhenItMovedByTwoHundredths() {
        defer { Chrome.ink = nil }
        let card = makeCard()
        card.setHeard("what is due", followUp: false)
        card.setReply(markdown: "Hello wonderful world", hiddenTail: 5)
        let height = card.fittingHeight
        card.setShade(level: 1, ink: 1)
        #expect(abs(carried(card.reply, 0).white - 0.07) < 0.003 && carried(card.reply, 0).alpha == 1)
        #expect(abs(carried(card.quote.text, 0).white - 0.07) < 0.003 && abs(carried(card.quote.text, 0).alpha - Chrome.dimAlpha) < 0.003)
        #expect(carried(card.reply, 20).alpha == 0)  // the hidden tail is still hidden
        card.setShade(level: 0.99, ink: 0.99)
        #expect(Chrome.ink == 0.99 && abs(carried(card.reply, 0).white - 0.07) < 0.003)  // under 0.02: the marks follow, the text is left
        card.setShade(level: 0.9, ink: 0.9)
        #expect(carried(card.reply, 0).white > 0.12)  // over: built again
        card.setShade(level: 0, ink: 0)
        #expect(abs(carried(card.reply, 0).white - 0.96) < 0.003 && abs(carried(card.quote.text, 0).white - 0.96) < 0.003)
        card.setShade(level: nil, ink: nil)
        #expect(Chrome.ink == nil)
        #expect((card.reply.textView.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor).isEqual(NSColor.labelColor))
        #expect(card.reply.string == "Hello wonderful world" && card.fittingHeight == height && carried(card.reply, 20).alpha == 0)  // only colours changed
    }

    @Test func theGlassShowsOneGlassOfTheSystemsModeUntilItHasAShadeAndNeverChangesAppearance() {
        let card = makeCard()
        let light = card.glass.subviews[0] as! NSGlassEffectView, dark = card.glass.subviews[1] as! NSGlassEffectView
        let systemDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        func oneSystemGlass() -> Bool {
            card.glass.level == nil && light.alphaValue == 1 && dark.alphaValue == 1 && light.isHidden == systemDark && dark.isHidden == !systemDark
        }
        #expect(oneSystemGlass())
        card.setShade(level: 0.5, ink: 0.5)
        #expect(!dark.isHidden && !light.isHidden)
        card.setShade(level: nil, ink: nil)
        #expect(oneSystemGlass())
        // changing a glass's appearance after it had rendered left it showing the old one on the live app: they are set once
        #expect(light.appearance?.name == .aqua && dark.appearance?.name == .darkAqua)
    }

    @Test func theLightGlassIsBelowAndTheDarkOneFadesOutAboveItAsTheLevelRises() {
        let card = makeCard()
        let light = card.glass.subviews[0] as! NSGlassEffectView, dark = card.glass.subviews[1] as! NSGlassEffectView
        #expect(dark.appearance?.name == .darkAqua)
        func show(_ level: Double) -> (light: Bool, dark: Bool) {
            card.glass.setShade(level)
            return (!light.isHidden, !dark.isHidden)
        }
        #expect(show(1) == (true, false) && light.appearance?.name == .aqua && light.alphaValue == 1)  // at rest only the light card shows
        #expect(show(0) == (false, true) && dark.alphaValue == 1)  // and only the dark one
        #expect(show(0.25) == (true, true) && light.alphaValue == 1 && dark.alphaValue == 0.75)
        #expect(show(0.5) == (true, true) && dark.alphaValue == 0.5)
        #expect(show(0.75) == (true, true) && dark.alphaValue == 0.25)
        #expect(show(1.7) == (true, false) && show(-3) == (false, true))  // out of range is the nearest end
        #expect(card.glass.subviews.firstIndex { $0 === light }! < card.glass.subviews.firstIndex { $0 === dark }!)  // light below
    }

    @Test func theGlassHasNoTint() {
        let card = makeCard()
        card.setShade(level: 0.4, ink: 0.4)
        #expect(card.glass.subviews.prefix(2).allSatisfy { ($0 as! NSGlassEffectView).tintColor == nil })
    }

    @Test func theVeilShowsOnceTheBackdropIsKnownAndLayoutIsUntouched() {
        let card = makeCard()
        fitted(card)
        card.setShade(level: 0.5, ink: 0.5)
        #expect(!card.glass.subviews.last!.isHidden)
        #expect(card.glass.subviews.allSatisfy { $0.frame == card.glass.bounds })  // every layer of the glass fills the pane
        #expect(card.glass.frame == NSRect(x: 6, y: 6, width: 328, height: card.frame.height - 6 - 9))
    }
}

// MARK: lights and header

@Suite @MainActor struct CardHeaderTests {
    @Test(arguments: [("unknown", "Agent"), ("ok", "Agent"), ("warn", "Agent …"), ("bad", "Agent problem")])
    func theAgentLightAlwaysCarriesAWord(_ state: String, _ label: String) {
        #expect(Led("Agent", state: LedState(rawValue: state)!).label == label)
    }

    @Test(arguments: [("ok", "Mic"), ("loading", "Mic …"), ("hot", "Listening"), ("off", "Mic off"), ("bad", "Mic problem")])
    func theMicLightAlwaysCarriesAWord(_ state: String, _ label: String) {
        #expect(Led("Mic", hot: "Listening", state: LedState(rawValue: state)!).label == label)
    }

    @Test func aStateThatMeansTroubleIsNotToldByColourAlone() {
        let labels = ["ok", "loading", "hot", "off", "bad"].map { Led("Mic", hot: "Listening", state: LedState(rawValue: $0)!).label }
        #expect(Set(labels).count == 5)  // five states, five different words
        #expect(LedState.allCases.count == 7)
    }

    @Test func micStateReadsTheListenerTheMindTheNoteAndTheFollowUpWindow() {
        func mic(_ ready: Bool?, _ activity: Activity, noted: Bool = false, following: Bool = false) -> LedState {
            CardView.micState(listenerReady: ready, activity: activity, noted: noted, following: following)
        }
        #expect(mic(nil, .idle) == .off)
        #expect(mic(nil, .listening) == .off)  // no listener: nothing is listening
        #expect(mic(nil, .idle, following: true) == .off)
        #expect(mic(false, .idle) == .loading)
        #expect(mic(true, .idle) == .ok)
        #expect(mic(true, .listening) == .hot)
        #expect(mic(true, .idle, noted: true) == .bad)
        #expect(mic(false, .idle, noted: true) == .bad)
        #expect(mic(true, .listening, noted: true) == .hot)  // the next wake clears it
        #expect(mic(true, .idle, following: true) == .hot)  // waiting for a reply without its name: "Listening"
        #expect(mic(true, .idle, noted: true, following: true) == .hot)
    }

    @Test func theHeaderLaysOutAgainWhenALabelGrows() {
        let card = makeCard()
        card.setLights(link: .warn, mic: .bad)
        let before = card.header.linkX
        card.setLights(link: .bad, mic: .hot)  // "Agent problem" is wider than "Agent …"
        #expect(card.header.link.label == "Agent problem" && card.header.mic.label == "Listening")
        #expect(card.header.linkX != before)
        #expect(card.header.micX >= card.header.linkX + card.header.link.width)
        #expect(card.header.micX + card.header.mic.width <= card.header.bounds.width)
    }

    @Test func blinkingAndPulsingFollowThePhaseTheWindowGives() {
        var warn = Led("Agent", state: .warn)
        #expect(warn.setPhase(0.0) == false)  // lit for half a second, dark for half, at 1 Hz
        #expect(warn.setPhase(0.6) && !warn.lit)
        #expect(warn.setPhase(1.0) && warn.lit)
        var ok = Led("Agent", state: .ok)
        #expect((0...4).allSatisfy { ok.setPhase(Double($0) * 0.1) == false })  // steady: nothing to redraw
        var hot = Led("Mic", hot: "Listening", state: .hot)
        #expect(hot.setPhase(0.0) == true && hot.pulse == 0.5)  // the pulse starts at the middle and peaks 0.3125 s in
        #expect(hot.setPhase(0.3125) && hot.pulse == 1.0)

        let card = makeCard()
        card.setLights(link: .warn, mic: .ok)
        card.setPhase(0.0)
        let lit = Bitmap(snap(card.header, scale: 2)).bytes
        card.setPhase(0.6)
        #expect(Bitmap(snap(card.header, scale: 2)).bytes != lit)  // and what is drawn really changes
    }

    @Test func aHealthyHeaderShowsNoLightsAndTroubleShowsAWord() {
        let card = makeCard()
        for state in [LedState.unknown, .ok, .loading, .off] {
            card.setLights(link: state, mic: state)
            #expect(card.header.link.width == 0 && card.header.mic.width == 0, "\(state)")
        }
        for state in [LedState.warn, .bad] {
            card.setLights(link: state, mic: .ok)
            #expect(card.header.link.width > 0 && card.header.mic.width == 0, "\(state)")
        }
        card.setLights(link: .ok, mic: .hot)
        #expect(card.header.link.width == 0 && card.header.mic.width > 0)
    }

    @Test func theDotsOfTheLightsAreOrangeAndRedAndNeutralWhenListening() {
        func dot(_ link: LedState) -> (r: Int, g: Int, b: Int, a: Int) {
            let card = makeCard()
            card.setLights(link: link, mic: .ok)
            return Bitmap(snap(card.header, scale: 2)).straight(card.header.linkX + 7, 13, dpr: 2)
        }
        let warn = dot(.warn), bad = dot(.bad)
        #expect(warn.a > 200 && warn.r > warn.b + 60 && warn.g > warn.b)  // orange (lit at phase 0)
        #expect(bad.a > 200 && bad.r > bad.g + 60 && bad.r > bad.b + 60)  // red
        let card = makeCard()
        card.setLights(link: .ok, mic: .hot)
        let listening = Bitmap(snap(card.header, scale: 2)).straight(card.header.micX + 7, 13, dpr: 2)
        #expect(listening.a > 80 && abs(listening.r - listening.b) < 12)
    }

    @Test func theHeaderShowsTheNameAsWrittenAndNothingOverlaps() {
        let card = makeCard(Themes.glass.with { $0.botName = "pixel" })
        #expect(card.header.shownName == "pixel")
    }

    @Test(arguments: ["Robo", "WWWWWWWWWWWW", "iiiiiiiiiiii"], [(LedState.ok, LedState.ok), (.bad, .hot), (.warn, .bad)])
    func theNameGivesWayBeforeTheLights(_ name: String, _ states: (LedState, LedState)) {
        let card = makeCard(Themes.glass.with { $0.botName = name })
        card.setLights(link: states.0, mic: states.1)
        let h = card.header
        #expect(h.micX + h.mic.width <= h.bounds.width - 12)  // the lights always fit: a long name is elided before they move
        #expect(h.shownName == name || h.shownName.hasSuffix("…"))
    }

    @Test func theHeaderTextIsPainted() {
        let card = makeCard()
        let img = Bitmap(snap(card.header, scale: 1))
        let row = (0..<328).map { img.at(Double($0), 13) }
        #expect(Set(row.map { "\($0.r),\($0.g),\($0.b),\($0.a)" }).count > 4)  // the name
    }

    @Test func theHeaderHasAHairlineUnderIt() {
        let card = makeCard()
        let img = Bitmap(snap(card.header, scale: 2))
        #expect(img.alpha(100, 25.5, dpr: 2) > 0 && img.alpha(2, 25.5, dpr: 2) == 0)  // from x = 8 to 8 short of the right edge
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
        let one = card.quote.text
        #expect(one.frame.height == CGFloat(Int(one.documentHeight)) + 2 && one.frame.height > 2)  // one line of 12 px italic, plus 2
        #expect(card.quote.height == 12 + 2 + one.frame.height + 7)
        let single = one.frame.height
        card.setHeard("what is due this week in the lab and the other class, and when " + String(repeating: "and more ", count: 6), followUp: false)
        #expect(card.quote.text.frame.height > single && card.quote.text.frame.height < CardView.heardMax)  // wraps to more lines: taller
        card.setHeard(String(repeating: "a very long question ", count: 40), followUp: false)
        #expect(card.quote.text.frame.height == CardView.heardMax && card.quote.text.overflows)
    }

    @Test func theQuotePaintsANeutralBarAndAFadingHairline() {
        let quote = QuoteView()
        quote.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        let img = Bitmap(snap(quote, scale: 2))
        let bar = img.straight(0.5, 10, dpr: 2)
        #expect(bar.a > 100 && abs(bar.r - bar.b) < 12 && abs(bar.r - bar.g) < 12)
        // the hairline at the foot: painted at the start, fading out to the right
        let near = img.alpha(30, 59.5, dpr: 2), middle = img.alpha(150, 59.5, dpr: 2), far = img.alpha(290, 59.5, dpr: 2)
        #expect(near > 0 && middle > 0 && near > middle && middle > far && far < 10)
    }

    @Test func aMicroLabelReadsAsASentenceInAGreyInk() {
        let label = MicroLabel("You")
        #expect(label.text == "You")
        label.text = "searching the web…"
        #expect(label.fitting.width > 60)
        label.frame = NSRect(origin: .zero, size: label.fitting)
        let painted = Bitmap(snap(label, scale: 2)).pixels.filter { $0.a > 20 }
        #expect(!painted.isEmpty && painted.allSatisfy { abs($0.r - $0.b) < 20 })
        #expect(Chrome.sentence("searching the web…") == "Searching the web…" && Chrome.sentence("") == "")
    }

    @Test func theStatusRowShowsTheDotsAndTheLabelOnlyWhileTheyAreOn() {
        let card = makeCard()
        var fits = 0
        card.fit = { fits += 1; $0() }
        card.setStatusRow(typing: false, label: "")
        #expect(fits == 0 && card.statusRow.isHidden)
        card.setStatusRow(typing: true, label: "searching the web…")
        #expect(fits == 1 && !card.statusRow.isHidden && card.statusRow.height == max(16, card.statusRow.label.fitting.height))
        card.setStatusRow(typing: true, label: "reading a page…")  // the same pair is no change
        #expect(fits == 1 && card.statusRow.label.text == "reading a page…")
        card.setStatusRow(typing: false, label: "listening")
        #expect(fits == 2 && card.statusRow.dots.isHidden && !card.statusRow.label.isHidden && card.statusRow.height == card.statusRow.label.fitting.height)
        card.setStatusRow(typing: false, label: "")
        #expect(fits == 3 && card.statusRow.isHidden)
        #expect(card.fittingHeight == 61)
    }
}

private extension MicroLabel {
    /// This label sized to its text, for a snapshot.
    func withFrame() -> MicroLabel { frame = NSRect(origin: .zero, size: fitting); return self }
}

// MARK: the typing dots

@Suite @MainActor struct CardDotsTests {
    @Test func theDotsKeepTheirWave() {
        let a = TypingDotsView.offsets(0.0), b = TypingDotsView.offsets(0.2)
        #expect(a.count == 3 && a != b && (a + b).map { abs($0) }.max()! <= TypingDotsView.hop)
    }

    @Test func theDotsHopInANeutralInkWithoutAPill() {
        let dots = TypingDotsView()
        dots.clock = { 0 }
        #expect(dots.frame.size == NSSize(width: 32, height: 16))
        let img = Bitmap(snap(dots, scale: 2))
        #expect(img.alpha(31, 8, dpr: 2) == 0 && img.alpha(0, 15, dpr: 2) == 0)  // no pill
        let first = img.straight(5, 8, dpr: 2)  // the first dot's column: always inside its dot
        #expect(first.a > 80 && abs(first.r - first.b) < 12 && abs(first.r - first.g) < 12)
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
    @Test(arguments: [12, 14, 16, 18]) func theCaretSitsInsideTheViewportAtTheEndOfTheText(_ textPx: Int) {
        let t = Themes.glass.with { $0.textPx = textPx }
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
            #expect(CGRect(origin: .zero, size: size).contains(CaretView.box(for: line, theme: Themes.glass, in: size)), "\(line)")
        }
    }

    @Test(arguments: ["block", "bar", "under"]) func theCaretIsABlockABarOrAnUnderline(_ style: String) {
        let t = Themes.glass.with { $0.caret = style }
        let box = CaretView.box(for: CGRect(x: 10, y: 20, width: 1, height: 17), theme: t, in: CGSize(width: 302, height: 120))
        let caret = CaretView()
        caret.shape = style
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

    @Test func theCaretIsPaintedInTheTextsInkAndNoColour() {
        let caret = CaretView()
        caret.frame = CGRect(x: 0, y: 0, width: 10, height: 18)
        let p = Bitmap(snap(caret)).straight(5, 9)
        #expect(p.a > 150 && abs(p.r - p.b) < 12 && abs(p.r - p.g) < 12, "\(p)")
    }

    @Test func theCaretTakesNoClicks() { #expect(CaretView().hitTest(NSPoint(x: 1, y: 1)) == nil) }

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

// MARK: the menu

@Suite @MainActor struct CardMenuTests {
    @Test func theMenuIsThreeByTwoAndWithoutAWatcherNudgesAndQuitShareTheSecondRow() {
        func grid(_ card: CardView) -> [String: [Int]] {
            Dictionary(uniqueKeysWithValues: card.chips.cells.map { ($0.0.title.split(separator: " ").last.map(String.init)!, [$0.1, $0.2, $0.3]) })
        }
        #expect(makeCard().chips.buttons.count == 6 && makeCard().chips.subviews.count == 6)  // digest, type, stay, watch, nudges, quit
        #expect(grid(makeCard()) == ["Digest": [0, 0, 2], "Type": [0, 2, 2], "Stay": [0, 4, 2], "Nudges": [1, 0, 3], "Quit": [1, 3, 3]])  // row, column, columns
        let watched = grid(makeCard(watch: true))
        #expect(watched == ["Digest": [0, 0, 2], "Type": [0, 2, 2], "Stay": [0, 4, 2], "Watch": [1, 0, 2], "Nudges": [1, 2, 2], "Quit": [1, 4, 2]])
    }

    @Test func theMenuChipsFillTheColumnInSixEqualColumns() {
        let card = makeCard(watch: true)
        card.showMenu()
        let rects = card.chips.buttons.map { $0.frame }  // digest, type, stay, watch, nudges, quit
        #expect(rects.map(\.width) == [97, 96, 97, 97, 96, 97] && rects.map(\.minY) == [0, 0, 0, 34, 34, 34])  // six columns of 45 1/3 and a gap of 6, edges rounded
        #expect(rects.map(\.height) == [28, 28, 28, 28, 28, 28] && card.chips.height == 62 && card.chips.frame.height == 62)
        #expect(rects[0].minX == 0 && rects[2].maxX == 302 && rects[1].minX - rects[0].maxX == 6 && rects[2].minX - rects[1].maxX == 6)
        #expect(rects[3].minX == 0 && rects[5].maxX == 302 && rects[4].minX - rects[3].maxX == 6 && rects[5].minX - rects[4].maxX == 6)  // watch | nudges | quit, two columns each
        let bare = makeCard()
        bare.showMenu()
        #expect(bare.chips.watch.isHidden)
        #expect(bare.chips.nudges.frame == NSRect(x: 0, y: 34, width: 148, height: 28) && bare.chips.quit.frame == NSRect(x: 154, y: 34, width: 148, height: 28))  // nudges | quit, three columns each
    }

    @Test(arguments: [true, false]) func theMenuButtonsStayInsideTheColumnAndNeverOverlap(_ watch: Bool) {
        let card = makeCard(watch: watch)
        card.showMenu()
        let shown = card.chips.buttons.filter { !$0.isHidden }
        #expect(shown.count == (watch ? 6 : 5))
        let column = NSRect(x: 0, y: 0, width: 302, height: 62)
        for (i, a) in shown.enumerated() {
            #expect(column.contains(a.frame), "\(a.title)")
            for b in shown[(i + 1)...] { #expect(!a.frame.intersects(b.frame), "\(a.title) over \(b.title)") }
        }
        #expect(card.chips.frame.width == 302 && card.chips.subviews.count == 6)
    }

    @Test func aMenuEntryHidesTheMenuBeforeItIsReported() {
        let card = makeCard(watch: true)
        var got: [(MenuAction, Bool)] = []
        card.onMenu = { got.append(($0, card.chips.isHidden)) }
        card.showMenu(staying: true, watchPaused: true, nudgesOn: false)
        #expect(card.chips.stay.title == "Wander" && card.chips.stay.symbol == "figure.walk" && card.chips.watch.symbol == "play" && card.chips.nudges.symbol == "bell.slash")
        #expect(card.chips.watch.accessibilityLabel() == "Resume watching" && card.chips.nudges.accessibilityLabel() == "Turn nudges on")
        card.chips.stay.onClick?()
        card.showMenu()
        #expect(card.chips.nudges.title == "Nudges" && card.chips.nudges.symbol == "bell")  // the default: on
        card.chips.digest.onClick?()
        card.showMenu()
        card.chips.type.onClick?()
        card.showMenu()
        card.chips.watch.onClick?()
        card.showMenu()
        card.chips.nudges.onClick?()
        card.showMenu()
        card.chips.quit.onClick?()
        #expect(got.map(\.0) == [.stay, .digest, .type, .watch, .nudges, .quit] && got.allSatisfy(\.1))
    }

    @Test func buttonsAreButtonsForAccessibilityAndClickWhenReleasedInside() {
        let card = makeCard(watch: true)
        #expect(card.chips.digest.accessibilityRole() == .button && card.chips.digest.accessibilityLabel() == "Digest")
        var clicks = 0
        card.chips.digest.onClick = { clicks += 1 }
        _ = card.chips.digest.accessibilityPerformPress()
        #expect(clicks == 1)

        let button = ButtonView("Allow", kind: .allow)
        button.frame = NSRect(x: 0, y: 0, width: 100, height: 28)
        button.onClick = { clicks += 1 }
        func release(at p: NSPoint) {
            button.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
        }
        release(at: NSPoint(x: 50, y: 14))
        #expect(clicks == 2)  // released inside
        release(at: NSPoint(x: 400, y: 14))
        #expect(clicks == 2)  // released outside: no click
    }

    @Test func theButtonKindsPaintAWashAnAccentFillAndAnOutline() {
        func shot(_ kind: ButtonView.Kind) -> Bitmap {
            let b = ButtonView("OK", kind: kind)
            b.frame = NSRect(x: 0, y: 0, width: 100, height: 28)
            return Bitmap(snap(b))
        }
        let plain = shot(.plain), allow = shot(.allow), deny = shot(.deny)
        #expect(plain.alpha(14, 14) > 5 && plain.alpha(14, 14) < 60)  // a quiet wash
        #expect(allow.alpha(14, 14) > 200)  // filled
        #expect(deny.alpha(14, 14) == 0 && deny.alpha(50, 0) > 0)  // outline only: empty inside, a hairline on the edge
        #expect(plain.alpha(1, 1) == 0)  // capsule: the corner is empty
        #expect(plain.bytes != allow.bytes && allow.bytes != deny.bytes)
    }

    @Test func theFitCallbackWrapsEveryChangeOfHeight() {
        let card = makeCard()
        var fits = 0, heights: [CGFloat] = []
        card.fit = { change in fits += 1; change(); heights.append(card.fittingHeight) }
        card.showMenu()
        card.setApproval("ok?")
        card.setApproval(nil)
        card.hideMenu()
        card.hideMenu()  // already hidden: nothing to fit
        #expect(fits == 4 && heights.first == 42 + 62 + 19 && heights.last == 61)
    }
}

// MARK: approval and footer

@Suite @MainActor struct CardApprovalTests {
    @Test func theApprovalShowsTheRequestAndReportsAllowAndDeny() {
        let card = makeCard()
        var choices: [String] = []
        card.onApprove = { choices.append($0) }
        card.setApproval("Run: ls -la")
        #expect(!card.approval.isHidden && card.approval.well.text == "Run: ls -la" && card.approval.label.text == "Approval")
        card.approval.allow.onClick?(); card.approval.deny.onClick?()
        #expect(choices == ["once", "deny"])
        card.setApproval(nil)
        #expect(card.approval.isHidden)
    }

    @Test func theApprovalSaysHowManyMoreWaitWithoutChangingTheLayout() {
        let card = makeCard()
        card.setApproval("Run: ls", more: 2)
        #expect(card.approval.label.text == "Approval +2 more" && card.approval.well.text == "Run: ls")
        let height = card.fittingHeight
        card.setApproval("Run: ls")  // the last one: back to the plain label
        #expect(card.approval.label.text == "Approval" && card.fittingHeight == height)
        #expect(card.approval.label.fitting.width < CardView.columnWidth)  // the longer label fits its row
        card.setApproval("Run: ls", more: 12)
        #expect(card.approval.label.fitting.width < CardView.columnWidth)
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
        card.setFooter("In Obsidian: Plan")
        #expect(card.footer.isHidden && card.fittingHeight == 61)
        card.showFooter()
        #expect(!card.footer.isHidden && card.footer.text == "In Obsidian: Plan" && card.fittingHeight == 42 + card.footer.height(for: 302) + 19)
        #expect(card.fittingHeight >= 81)
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

    @Test func theApprovalAndFooterPaintOnlyTheirOwnMarksOnTheGlass() {
        let approval = ApprovalView()
        approval.well.text = "Run: ls -la"
        approval.frame = NSRect(x: 0, y: 0, width: 302, height: approval.height(for: 302))
        approval.place()
        let img = Bitmap(snap(approval))
        #expect(img.alpha(0.5, approval.well.frame.midY) > 200)  // the well's orange bar
        #expect(img.at(0.5, approval.well.frame.midY).r > img.at(0.5, approval.well.frame.midY).b)
        #expect(img.alpha(150, approval.well.frame.minY + 2) > 0)  // and the wash inside the well
        let footer = WrapLabelView(.footer)
        footer.text = "In Obsidian: Plan"
        footer.frame = NSRect(x: 0, y: 0, width: 302, height: footer.height(for: 302))
        let f = Bitmap(snap(footer))
        #expect(f.alpha(150, 0) > 0 && f.alpha(150, 2) == 0)  // the hairline above the text
    }
}

// MARK: the nudge

@Suite @MainActor struct CardNudgeTests {
    private func one(url: String? = "https://moodle.example.edu/mod/assign/view.php?id=7") -> NudgeText {
        NudgeText([NudgeCandidate(id: "a", category: .deadline, title: "MATH201 midterm", detail: "tomorrow 09:00", url: url)])
    }

    /// Found live (2026-10-20): a deadline read from a post had a quote that fit one line when measured and wrapped when drawn (the
    /// well draws with `.kern: 0`, which turns pair kerning off), so the well was a line short and the domain line was cut off.
    @Test func aWellMeasuresTextTheWayItIsDrawn() {
        _ = NSApplication.shared
        let font = Chrome.ui(12), quote = "“Hand in the demo problem set within two hours.”"
        let drawn = Chrome.advance(quote, font)  // with kern 0, as the well draws it
        let kerned = NSAttributedString(string: quote, attributes: [.font: font]).size().width
        #expect(kerned < drawn - 0.5, "this text no longer separates the two ways of measuring: pick another")
        let well = WrapLabelView(.well)
        let inset = 10 + (Chrome.advance("x", font) / 2).rounded(.down) + 8  // the well's left and right insets
        well.text = "x"
        let line = well.height(for: 1000) - 12  // one line, plus 6 above and 6 below
        well.text = quote
        #expect(well.height(for: drawn - 0.5 + inset) == 12 + 2 * line)  // one point too narrow for how it is drawn: two lines
        #expect(well.height(for: drawn + 1 + inset) == 12 + line)  // and room enough: one
    }

    @Test func aNudgeShowsLabelTitleWhyAndDomainAndReportsTheThreeButtons() {
        let card = makeCard()
        var got: [NudgeBudget.Outcome] = []
        card.onNudge = { got.append($0) }
        card.setNudge(one())
        #expect(!card.nudge.isHidden && card.nudge.label.text == "Heads-up")
        #expect(card.nudge.well.text == "MATH201 midterm\ntomorrow 09:00\n↗ moodle.example.edu")
        #expect(!card.nudge.open.isHidden)
        card.nudge.open.onClick?(); card.nudge.later.onClick?(); card.nudge.notForMe.onClick?()
        #expect(got == [.opened, .later, .notForMe])
        card.setNudge(nil)
        #expect(card.nudge.isHidden && card.fittingHeight == 61)
    }

    @Test func openIsOnlyThereWhenThereIsAnHttpsLinkAndTheOtherButtonsShareTheRow() {
        let card = makeCard()
        card.setNudge(one(url: nil))
        #expect(card.nudge.open.isHidden && card.nudge.well.text == "MATH201 midterm\ntomorrow 09:00")  // no link, no domain line
        fitted(card)
        #expect(card.nudge.later.frame.width == 147 && card.nudge.notForMe.frame == NSRect(x: 155, y: card.nudge.later.frame.minY, width: 147, height: 28))
        card.setNudge(one(url: "http://moodle.example.edu/x"))  // plain http is no link robo opens
        #expect(card.nudge.open.isHidden)
        card.setNudge(one())
        fitted(card)
        let row = [card.nudge.open, card.nudge.later, card.nudge.notForMe].map(\.frame)
        #expect(row.map(\.width) == [95, 96, 95] && row[0].minX == 0 && row[2].maxX == 302 && row[1].minX - row[0].maxX == 8 && row[2].minX - row[1].maxX == 8)
    }

    @Test func theNudgeGrowsWithItsTextAndJoinsTheColumnLikeTheApproval() {
        let card = makeCard()
        card.setNudge(one())
        let short = card.fittingHeight, n = card.nudge
        #expect(short == 42 + n.height(for: 302) + 19 && n.height(for: 302) == 12 + 6 + n.well.height(for: 302) + 6 + 28)
        card.setNudge(NudgeText((0..<5).map { NudgeCandidate(id: "\($0)", category: .deadline, title: String(repeating: "word ", count: 12), detail: "tomorrow 09:00") }))
        #expect(card.fittingHeight > short + 30)
        fitted(card)
        #expect(n.frame == NSRect(x: 19, y: 42, width: 302, height: n.height(for: 302)) && n.later.frame.maxY == n.frame.height)
        card.showMenu()  // the menu sits above it, the column's 8 between
        #expect(card.fittingHeight == 42 + card.chips.height + 8 + n.height(for: 302) + 19)
    }

    @Test func severalThingsMakeOneCardWithACountAndAtMostThreeLines() {
        func c(_ i: Int, _ category: NudgeCategory = .deadline) -> NudgeCandidate {
            NudgeCandidate(id: "\(i)", category: category, title: "Thing \(i)", detail: "tomorrow 09:00", url: "https://a.example/\(i)")
        }
        let deadlines = NudgeText([c(1), c(2), c(3)])
        #expect(deadlines.title == "3 things due soon" && deadlines.lines == ["Thing 1 · tomorrow 09:00", "Thing 2 · tomorrow 09:00", "Thing 3 · tomorrow 09:00"])
        #expect(deadlines.domain == nil && !deadlines.canOpen)  // which link would Open take?
        let mixed = NudgeText([c(1), c(2, .event), c(3), c(4), c(5)])
        #expect(mixed.title == "5 things coming up" && mixed.lines.count == 4 && mixed.lines.last == "+ 2 more")
        #expect(NudgeText([NudgeCandidate(id: "x", category: .opportunity, title: "Programme", detail: "")]).label == "Worth a look")
    }

    @Test func theNudgePaintsItsWellAndButtonsOnTheGlass() {
        let nudge = NudgeView()
        nudge.well.text = "MATH201 midterm\ntomorrow 09:00"
        nudge.frame = NSRect(x: 0, y: 0, width: 302, height: nudge.height(for: 302))
        nudge.place()
        let img = Bitmap(snap(nudge))
        let wash = img.straight(20, nudge.well.frame.midY)  // a neutral note, no warning colour
        #expect(wash.a > 0 && abs(wash.r - wash.b) < 12)
        let open = nudge.open.frame
        #expect(img.alpha(open.midX, open.minY + 3) > 0)  // the filled capsule
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

    @Test func keepingTheWidthDecidesLikeMeasuringAgainAtEveryTick() {
        let words = (0..<400).map { "word\($0 % 17)" }
        for cap in [90.0, 300.0] {
            let kept = TextBox(width: 302)
            var sizes = Array(stride(from: 1, through: 400, by: 7)); sizes += sizes.reversed()  // growing, then shrinking
            for n in sizes {
                let md = words.prefix(n).joined(separator: " ")
                kept.setContent(Markdown.attributed(md, theme: Themes.glass))
                let fresh = TextBox(width: 302)
                fresh.setContent(Markdown.attributed(md, theme: Themes.glass))
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
        card.setTheme(Themes.glass.with { $0.textPx = 16 })  // the window renders again at once in the new look
        card.setReply(markdown: "fresh again", hiddenTail: 0)
        #expect(card.reply.string == "fresh again")
    }

    @Test func theTextStaysClearOfTheScroller() {
        let card = makeCard()
        card.setReply(markdown: "short", hiddenTail: 0)
        #expect(!card.reply.overflows && card.reply.textView.frame.width == 302)
        card.setReply(markdown: longReply, hiddenTail: 0)
        #expect(card.reply.overflows && card.reply.textView.frame.width == 302 - TextBox.scrollerRoom)
    }

    /// A reply that overflows is laid out at the width with the scroller on every tick, not at both widths: the typing tick of a
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
        fitted(card)
        card.glass.isHidden = true  // only what the card itself draws
        let img = Bitmap(snap(card, scale: 1))
        let inBox = img.alpha(160, card.reply.frame.maxY - 8)  // inside the code box, right of the text
        #expect(inBox > 5 && inBox < 60)  // the box is a quiet wash of the label colour (7 %), whichever appearance
        #expect(img.alpha(160, card.reply.frame.minY + 8) == 0)  // the first line, right of its text: nothing
        let text = img.pixels.filter { $0.a > 200 && $0.y < Int(card.reply.frame.minY) + 20 && $0.x >= 19 && $0.x < 60 }
        #expect(!text.isEmpty)  // and the letters
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
        card.reply.textView.confirmLink = { _, _ in true }  // the alert is asked in its own tests
        card.reply.textView.openLink = { opened.append($0) }
        card.setReply(markdown: "see [the notes](\(link))", hiddenTail: 0)
        card.reply.textView.clicked(onLink: URL(string: link)!, at: 5)
        #expect(opened == [URL(string: link)!])
        #expect(card.reply.string == "see the notes")  // the link is not typed into the text
    }

    /// The reply is a model's text built from mail: `[grades](https://evil.example/?d=SECRET)` must not leave on one click. A click
    /// asks first, with the full address and the words that showed it, and only "Open" opens.
    @Test func aLinkAsksWithItsFullAddressAndItsWordsAndOpensOnlyOnOpen() {
        let card = makeCard()
        let address = "https://evil.example/collect?d=SECRET&more=1#frag"
        var asked: [(url: URL, words: String)] = [], opened: [URL] = [], answer = false
        card.reply.textView.confirmLink = { asked.append(($0, $1)); return answer }
        card.reply.textView.openLink = { opened.append($0) }
        card.setReply(markdown: "see [your grades](\(address)) now", hiddenTail: 0)
        card.reply.textView.clicked(onLink: URL(string: address)!, at: 6)  // Cancel
        #expect(asked.count == 1 && asked[0].url.absoluteString == address && asked[0].words == "your grades")
        #expect(opened.isEmpty)
        answer = true  // Open
        card.reply.textView.clicked(onLink: URL(string: address)!, at: 6)
        #expect(asked.count == 2 && opened == [URL(string: address)!])
    }

    @Test func theWordsAskedWithAreWhatTheReaderSawOrNothing() {
        let card = makeCard()
        var words: [String] = []
        card.reply.textView.confirmLink = { words.append($1); return false }
        card.setReply(markdown: "go to <https://example.com/a> or [x](mailto:a@b.c)", hiddenTail: 0)
        card.reply.textView.clicked(onLink: URL(string: "https://example.com/a")!, at: 8)
        card.reply.textView.clicked(onLink: URL(string: "mailto:a@b.c")!, at: 0)  // no link text at 0: no words
        #expect(words == ["https://example.com/a", ""])
    }

    /// The alert also says what the source check found (it needs no request, so the text is a pure function of the address and the words).
    @Test func theLinkAlertSaysWhatTheSourceCheckFound() throws {
        func text(_ link: String, _ words: String = "") -> (title: String, body: String, open: String) {
            BoxTextView.alertText(for: URL(string: link)!, words: words)
        }
        let known = text("https://arxiv.org/abs/2410.01234", "the paper")
        #expect(known.title == "Open this link?" && known.open == "Open")
        #expect(known.body.hasPrefix("https://arxiv.org/abs/2410.01234\n\nThe link text says “the paper”.\n\n✓ A primary source (arxiv.org)."))
        let plain = text("https://example.org/page")
        #expect(plain.title == "Open this link?" && plain.open == "Open" && plain.body.contains("Not on Robo's list of known sources"))
        let careful = text("https://bit.ly/3abc")
        #expect(careful.title == "Open this link?" && careful.open == "Open anyway" && careful.body.contains("⚠ Be careful with this link.") && careful.body.contains("shortened"))
        let scam = text("https://paypal.com.evil.xyz/login")
        #expect(scam.title == "This link looks like a scam" && scam.open == "Open anyway" && scam.body.contains("⚠ This looks like a scam."))
        // the classic: words that name one site on a link that goes to another
        let mismatch = text("https://evil.example.xyz/collect", "paypal.com")
        #expect(mismatch.title == "This link looks like a scam" && mismatch.body.contains("The link says “paypal.com” but goes to evil.example.xyz"))
        #expect(!text("mailto:a@b.example").body.contains("Robo's list"))  // a mail address is not a website
    }

    /// With no running app (every test) the default asks nothing and says no, so a test that forgets to replace it opens nothing.
    @Test func theDefaultAnswerWithoutARunningAppIsNo() throws {
        try #require(!NSApplication.shared.isRunning)
        #expect(!BoxTextView.askToOpen(URL(string: "https://example.com/")!, "example"))
    }

    /// The reply is a model's text built from mail, Teams and Moodle: a link in it may not open a file, a share or an app.
    @Test(arguments: ["file:///etc/passwd", "smb://host/share", "javascript:alert(1)", "robo://x", "ftp://host/f", "x-apple.systempreferences:com.apple.preference.security",
                      "tel:123", "data:text/html,hi", "/relative/path", "example.com", "vnc://host", "FILE:///Users"])
    func aLinkToAnythingElseDoesNothing(_ link: String) {
        let card = makeCard()
        var opened: [URL] = [], asked = 0
        card.reply.textView.confirmLink = { _, _ in asked += 1; return true }
        card.reply.textView.openLink = { opened.append($0) }
        card.reply.textView.clicked(onLink: URL(string: link)!, at: 0)
        card.reply.textView.clicked(onLink: link, at: 0)  // the link can come as a string too
        #expect(opened.isEmpty && asked == 0)  // not even asked about
    }

    @Test func theReplyIsSelectableButNeverEditable() {
        let card = makeCard()
        #expect(card.reply.textView.isSelectable && !card.reply.textView.isEditable)
        #expect(card.reply.textView.acceptsFirstMouse(for: nil))  // a click in a window that is not key still works
    }

    /// CLAUDE.md: a typing tick costs about 3 ms in Qt (`setMarkdown`), 30 times a second for a few seconds.
    @Test func aTypingStepIsCheap() {
        let card = makeCard()
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

// MARK: accessibility: the keyboard on the buttons, Increase Contrast

@MainActor @Suite(.serialized) struct CardAccessibilityTests {
    private func key(_ code: UInt16, _ chars: String, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func spaceAndReturnPressAButtonButNeverAHiddenOne() {
        let b = ButtonView("Allow", kind: .allow)
        var presses = 0
        b.onClick = { presses += 1 }
        #expect(b.acceptsFirstResponder && b.canBecomeKeyView)
        b.keyDown(with: key(49, " "))
        b.keyDown(with: key(36, "\r"))
        #expect(presses == 2)
        b.isHidden = true
        b.keyDown(with: key(49, " "))
        #expect(presses == 2 && !b.canBecomeKeyView)
        #expect(b.accessibilityRole() == .button && b.accessibilityLabel() == "Allow")
    }

    @Test func tabGoesBetweenAllowAndDenyAndVoiceOverHearsTheRequest() {
        let card = makeCard()
        card.setApproval("rm -rf build")
        #expect(card.approval.allow.nextKeyView === card.approval.deny && card.approval.deny.nextKeyView === card.approval.allow)
        #expect(card.approval.allow.accessibilityHelp() == "rm -rf build" && card.approval.deny.accessibilityHelp() == "rm -rf build")
        #expect(card.nudge.open.nextKeyView === card.nudge.later && card.nudge.notForMe.nextKeyView === card.nudge.open)
    }

    @Test func inAKeyWindowDenyTakesTheFocusAndAnApprovalThatGoesTakesItAway() {
        let card = makeCard()
        let window = NSPanel(contentRect: NSRect(x: 100_000, y: 100_000, width: 340, height: 400), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        guard window.isKeyWindow else { return }  // a locked screen gives no key window; the rest is the same code path
        card.setApproval("send the mail")
        #expect(window.firstResponder === card.approval.deny)  // the safe answer, not Allow
        card.setApproval(nil)
        #expect(window.firstResponder !== card.approval.deny && window.firstResponder !== card.approval.allow)
    }

    @Test func increaseContrastDrawsTheInkAtFullStrengthAndStrengthensTheVeil() {
        let keep = Chrome.increaseContrast
        defer { Chrome.increaseContrast = keep }
        Chrome.increaseContrast = { false }
        #expect(abs(Chrome.textDim(0.5).alphaComponent - Chrome.dimAlpha) < 0.001 && GlassSurface.lightVeil == 0.70 && GlassSurface.darkVeil == 0.72)
        Chrome.increaseContrast = { true }
        #expect(Chrome.text(0.5).alphaComponent == 1 && Chrome.textDim(0.5).alphaComponent == 1)
        #expect(abs(Chrome.hairline(0.5).alphaComponent - 0.36) < 0.001 && GlassSurface.lightVeil == 0.85 && GlassSurface.darkVeil == 0.85)
    }
}
