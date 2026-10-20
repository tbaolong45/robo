// The card's shade (pure): which way a backdrop's luma sends it, the hysteresis, the ease, the ink and the mean luma of
// a BGRA image. No UI and no clock: the ease is driven with dt.
import Foundation
import Testing
@testable import RoboCore

private func shade(after lumas: Double?...) -> Shade {
    var s = Shade()
    for l in lumas { s.see(luma: l) }
    return s
}

@Suite struct ShadeTests {
    @Test func aDarkBackdropWantsALightCardAndABrightOneADarkCard() {
        #expect(shade(after: 0.0).target == 1 && shade(after: 0.41).target == 1)
        #expect(shade(after: 1.0).target == 0 && shade(after: 0.59).target == 0)
    }

    /// The edges are exclusive (0.42 and 0.58 themselves are in the band) and the band keeps the last choice.
    @Test(arguments: [(0.42, 0.0, 0.0), (0.42, 1.0, 1.0), (0.58, 0.0, 0.0), (0.58, 1.0, 1.0), (0.5, 0.0, 0.0), (0.5, 1.0, 1.0)])
    func theBandBetweenTheEdgesKeepsTheLastTarget(_ luma: Double, _ before: Double, _ kept: Double) {
        var s = shade(after: before == 1 ? 0.0 : 1.0)  // dark backdrop -> target 1, bright -> 0
        #expect(s.target == before)
        s.see(luma: luma)
        #expect(s.target == kept)
    }

    @Test func aLumaWobblingAroundOneHalfNeverFlips() {
        var s = shade(after: 0.1)  // light card
        for luma in [0.45, 0.5, 0.55, 0.43, 0.57, 0.5, 0.49, 0.51] { s.see(luma: luma) }
        #expect(s.target == 1)
        s.see(luma: 0.9)
        for luma in [0.55, 0.5, 0.45, 0.57, 0.43, 0.5] { s.see(luma: luma) }
        #expect(s.target == 0)  // and stays on the other side once it went there
    }

    @Test func theFirstLookInTheBandPicksBySideOfOneHalf() {
        #expect(shade(after: 0.49).target == 1 && shade(after: 0.5).target == 0 && shade(after: 0.55).target == 0)
    }

    @Test func nothingIsKnownBeforeTheFirstLookAndAFailedOneIsNotALook() {
        #expect(Shade().known == false && Shade().level == 0 && !Shade().moving)
        let s = shade(after: nil, nil, nil, nil)
        #expect(!s.known && s.level == 0 && s.target == 0)
    }

    @Test func theFirstLookArrivesAtOnceNothingEasesFromTheSystemLook() {
        var s = Shade()
        s.see(luma: 0.0)
        #expect(s.known && s.level == 1 && s.target == 1 && !s.moving)
        let moving = s.step(dt: 0.033)
        #expect(!moving)
    }

    @Test func aLaterChangeEasesAndAnIsolatedFailureKeepsTheLook() {
        var s = shade(after: 0.0)
        s.see(luma: nil); s.see(luma: nil)  // two misses: still the same look
        #expect(s.known && s.level == 1)
        s.see(luma: 0.9)  // a miss in between does not count against later looks
        #expect(s.known && s.target == 0 && s.level == 1 && s.moving)
        s.see(luma: nil); s.see(luma: nil)
        s.see(luma: 0.9)
        s.see(luma: nil); s.see(luma: nil)
        #expect(s.known)  // never three in a row
    }

    @Test func threeFailedLooksInARowGoBackToTheSystemLookAndTheNextGoodOneIsKnownAgain() {
        var s = shade(after: 0.0)
        for _ in 0..<Shade.forget { s.see(luma: nil) }
        #expect(!s.known)
        s.see(luma: 0.9)  // back: no ease from a look that was not on screen
        #expect(s.known && s.level == 0 && s.target == 0 && !s.moving)
    }

    // MARK: the ease

    @Test func theLevelEasesTowardTheTargetAndNeverOvershoots() {
        for (start, goal) in [(1.0, 0.0), (0.0, 1.0)] {
            var s = shade(after: start == 1 ? 0.0 : 1.0)  // at rest at `start`
            s.see(luma: goal == 1 ? 0.0 : 1.0)
            var trail = [s.level]
            while trail.count < 100 && s.step(dt: 1.0 / 30) { trail.append(s.level) }
            trail.append(s.level)
            #expect(s.level == goal && !s.moving)
            let toward = trail.map { abs(goal - $0) }
            #expect(zip(toward, toward.dropFirst()).allSatisfy { $0 > $1 || $0 == 0 })  // strictly closer every step
            #expect(trail.allSatisfy { (0.0...1.0).contains($0) })
            #expect(trail.count > 6 && trail.count < 25, "\(trail.count) steps at 30 Hz")  // a fraction of a second, with distinct frames
        }
    }

    @Test func aStepOfOneTimeConstantCoversSixtyThreePercentOfTheWay() {
        var s = shade(after: 0.0)
        s.see(luma: 1.0)
        let moving = s.step(dt: Shade.tau)
        #expect(moving)
        #expect(abs(s.level - exp(-1.0)) < 1e-9)  // 1 -> 0: a distance of 1 - e^-1 covered
    }

    @Test func theEaseSnapsWithinAHundredthAndThenIsAtRest() {
        var s = shade(after: 0.0)
        s.see(luma: 1.0)
        let early = s.step(dt: 0.5)  // 1 -> 0.0155 after 0.5 s: not yet
        #expect(early && s.level > 0.01)
        let arrived = s.step(dt: 0.1)  // 0.0067: under 0.01, so it arrives
        #expect(!arrived && s.level == 0 && !s.moving)
        let after = s.step(dt: 1)
        #expect(!after && s.level == 0)
    }

    @Test func noTimeNoMovementAndNegativeTimeNoMovement() {
        var s = shade(after: 0.0)
        s.see(luma: 1.0)
        let none = s.step(dt: 0), negative = s.step(dt: -1)
        #expect(none && negative && s.level == 1)  // still moving, nowhere yet
    }

    @Test func aTargetChangedMidwayTurnsAroundFromWhereItIs() {
        var s = shade(after: 0.0)
        s.see(luma: 1.0)
        _ = s.step(dt: 0.1)
        let mid = s.level
        #expect(mid < 1 && mid > 0)
        s.see(luma: 0.0)  // the backdrop went dark again
        _ = s.step(dt: 0.05)
        #expect(s.level > mid && s.target == 1)
    }

    @Test func snapArrivesAtOnce() {
        var s = shade(after: 0.0)
        s.see(luma: 1.0)
        s.snap()
        #expect(s.level == 0 && !s.moving)
    }

    // MARK: the ink

    @Test func theInkIsDarkOnALightCardAndLightOnADarkOne() {
        #expect(shade(after: 0.0).ink == 1 && shade(after: 1.0).ink == 0)
    }

    @Test(arguments: [(0.0, 0.0), (0.2, 0.0), (0.35, 0.0), (0.425, 0.1562), (0.5, 0.5), (0.575, 0.8437), (0.65, 1.0), (0.8, 1.0), (1.0, 1.0)])
    func theInkSmoothstepsBetweenThirtyFiveAndSixtyFiveHundredths(_ level: Double, _ ink: Double) {
        var s = Shade()
        s.level = level
        #expect(abs(s.ink - ink) < 0.001, "level \(level) ink \(s.ink)")
    }

    @Test func theInkNeverGoesBackwardsOnTheWayUp() {
        var s = shade(after: 1.0)
        s.see(luma: 0.0)
        var inks = [s.ink]
        while s.step(dt: 1.0 / 30) { inks.append(s.ink) }
        inks.append(s.ink)
        #expect(inks.first == 0 && inks.last == 1)
        #expect(zip(inks, inks.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(inks.filter { $0 > 0 && $0 < 1 }.count <= 3)  // the flip takes a frame or two of the ease, not all of it
    }

    // MARK: the mean luma

    private func buffer(_ pixels: Int, b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 255) -> [UInt8] {
        (0..<pixels).flatMap { _ in [b, g, r, a] }
    }

    @Test func blackIsZeroWhiteIsOneAndHalfGreyIsAboutAHalf() {
        #expect(Shade.meanLuma(bgra: buffer(16, b: 0, g: 0, r: 0), width: 4, height: 4) == 0)
        #expect(Shade.meanLuma(bgra: buffer(16, b: 255, g: 255, r: 255), width: 4, height: 4)! > 0.9999)
        let half = Shade.meanLuma(bgra: buffer(6, b: 128, g: 128, r: 128), width: 3, height: 2)!
        #expect(abs(half - 128.0 / 255) < 1e-9)
    }

    @Test func halfBlackHalfWhiteIsAHalf() {
        let px = buffer(8, b: 0, g: 0, r: 0) + buffer(8, b: 255, g: 255, r: 255)
        #expect(abs(Shade.meanLuma(bgra: px, width: 4, height: 4)! - 0.5) < 1e-9)
    }

    @Test func theChannelsAreWeightedAsRec709AndTheOrderIsBGRA() {
        let blue = Shade.meanLuma(bgra: [255, 0, 0, 255], width: 1, height: 1)!
        let green = Shade.meanLuma(bgra: [0, 255, 0, 255], width: 1, height: 1)!
        let red = Shade.meanLuma(bgra: [0, 0, 255, 255], width: 1, height: 1)!
        #expect(abs(blue - 0.0722) < 1e-9 && abs(green - 0.7152) < 1e-9 && abs(red - 0.2126) < 1e-9)
    }

    @Test func alphaDoesNotCount() {
        #expect(Shade.meanLuma(bgra: buffer(4, b: 200, g: 200, r: 200, a: 0), width: 2, height: 2) == Shade.meanLuma(bgra: buffer(4, b: 200, g: 200, r: 200), width: 2, height: 2))
    }

    @Test func anEmptyOrShortBufferHasNoLuma() {
        #expect(Shade.meanLuma(bgra: [], width: 0, height: 0) == nil)
        #expect(Shade.meanLuma(bgra: [1, 2, 3, 4], width: 0, height: 1) == nil)
        #expect(Shade.meanLuma(bgra: [1, 2, 3, 4], width: 2, height: 2) == nil)  // too few bytes for the size
    }
}
