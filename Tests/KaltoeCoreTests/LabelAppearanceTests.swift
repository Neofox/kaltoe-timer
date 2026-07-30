import XCTest
@testable import KaltoeCore

final class LabelAppearanceTests: XCTestCase {

    // MARK: LabelPhase

    func testIdlePhases() {
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .noSession, urgency: .normal)), .idle)
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .notClockedIn, urgency: .normal)), .idle)
    }

    func testWorkingPhases() {
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .toLunch(timeLeft: 60), urgency: .normal)),
                       .working)
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .onBreak(timeLeft: 60), urgency: .normal)),
                       .working)
        // Still `.working` at critical urgency: inside the last ten minutes the
        // spectrum is already amber because of where it sits in the day, and colour
        // no longer keys off Urgency at all.
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .counting(timeLeft: 60), urgency: .critical)),
                       .working)
    }

    func testOvertimeSeparatesTheLimitFromOrdinaryOvertime() {
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .overtime(today: 3600, clockedIn: true),
                                              urgency: .warning)), .overtime)
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .overtime(today: 3600, clockedIn: true),
                                              urgency: .critical)), .atLimit)
    }

    /// `clockedIn` is authoritative, not urgency. `hasReachedWeeklyCap` returns
    /// critical off the clock too, so an urgency-first mapping would paint a
    /// finished day red.
    func testAClockedOutDayIsSettledEvenAtTheWeeklyCap() {
        XCTAssertEqual(LabelPhase(MenuDisplay(state: .overtime(today: 3600, clockedIn: false),
                                              urgency: .critical)), .settled)
    }

    // MARK: LabelPalette

    func testSpectrumHitsEachStopExactly() {
        XCTAssertEqual(LabelPalette.spectrum(0), LabelPalette.stops[0])
        XCTAssertEqual(LabelPalette.spectrum(1.0 / 3.0), LabelPalette.stops[1])
        XCTAssertEqual(LabelPalette.spectrum(2.0 / 3.0), LabelPalette.stops[2])
        XCTAssertEqual(LabelPalette.spectrum(1), LabelPalette.stops[3])
    }

    func testSpectrumInterpolatesBetweenStops() {
        let mid = LabelPalette.spectrum(1.0 / 6.0)
        let a = LabelPalette.stops[0].dark, b = LabelPalette.stops[1].dark
        XCTAssertEqual(mid.dark.red, (a.red + b.red) / 2, accuracy: 0.0001)
        XCTAssertEqual(mid.dark.green, (a.green + b.green) / 2, accuracy: 0.0001)
        XCTAssertEqual(mid.dark.blue, (a.blue + b.blue) / 2, accuracy: 0.0001)
    }

    /// `dayProgress` already guarantees 0...1, but this is public surface and must
    /// not index out of bounds.
    /// `NaN` takes the guard; the infinities are handled by the clamp itself, so
    /// they land on the ends rather than being funnelled to the first stop.
    func testSpectrumClampsAndSurvivesNonFiniteInput() {
        XCTAssertEqual(LabelPalette.spectrum(-1), LabelPalette.stops[0])
        XCTAssertEqual(LabelPalette.spectrum(2), LabelPalette.stops[3])
        XCTAssertEqual(LabelPalette.spectrum(.nan), LabelPalette.stops[0])
        XCTAssertEqual(LabelPalette.spectrum(.infinity), LabelPalette.stops[3])
        XCTAssertEqual(LabelPalette.spectrum(-.infinity), LabelPalette.stops[0])
    }

    func testWorkingDayTakesItsFillFromTheSpectrum() {
        let c = LabelPalette.resolve(progress: 0, phase: .working)
        XCTAssertEqual(c.fill, .pair(LabelPalette.stops[0]))
        XCTAssertNil(c.glyphTint)
        XCTAssertFalse(c.dashed)
    }

    /// The alerting colours defer to the system rather than carrying tuned values, so
    /// the label's orange past target is the same orange the popover's week strip
    /// already draws.
    func testOvertimeAndLimitAreFlatAndTintTheGlyph() {
        let ot = LabelPalette.resolve(progress: 1, phase: .overtime)
        XCTAssertEqual(ot.fill, .systemOrange)
        XCTAssertEqual(ot.glyphTint, .systemOrange)

        let limit = LabelPalette.resolve(progress: 1, phase: .atLimit)
        XCTAssertEqual(limit.fill, .systemRed)
        XCTAssertEqual(limit.glyphTint, .systemRed)
    }

    /// Progress is ignored past target — the colour is discrete there, so a
    /// half-filled ring cannot come out orange-ish.
    func testOvertimeColourIgnoresProgress() {
        XCTAssertEqual(LabelPalette.resolve(progress: 0.2, phase: .overtime).fill,
                       LabelPalette.resolve(progress: 1, phase: .overtime).fill)
        XCTAssertEqual(LabelPalette.resolve(progress: 0.2, phase: .overtime).fill,
                       .systemOrange)
    }

    func testIdleIsDashedAndNeutral() {
        let c = LabelPalette.resolve(progress: 0, phase: .idle)
        XCTAssertTrue(c.dashed)
        XCTAssertEqual(c.fill, .pair(LabelPalette.neutral))
    }

    func testSettledIsNeutralAndNotDashed() {
        let c = LabelPalette.resolve(progress: 0.7, phase: .settled)
        XCTAssertFalse(c.dashed)
        XCTAssertEqual(c.fill, .pair(LabelPalette.neutral))
        XCTAssertNil(c.glyphTint)
    }

    func testHexInitialiserUnpacksChannels() {
        let c = RGBA(0x5aa9f8)
        XCTAssertEqual(c.red, 0x5a / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c.green, 0xa9 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c.blue, 0xf8 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(c.alpha, 1)
    }

    func testGeometryIsStringBacked() {
        XCTAssertEqual(LabelGeometry(rawValue: "track"), .track)
        XCTAssertEqual(LabelGeometry.allCases, [.ring, .track])
    }
}
