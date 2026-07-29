import XCTest
@testable import KaltoeCore

final class MenuLabelStyleTests: XCTestCase {
    func testNormalIsPlainWhenHighContrastOff() {
        XCTAssertEqual(MenuLabelStyle.resolve(urgency: .normal, highContrast: false), .plain)
    }

    func testNormalIsSolidWhenHighContrastOn() {
        XCTAssertEqual(MenuLabelStyle.resolve(urgency: .normal, highContrast: true), .solid)
    }

    /// Urgency colour outranks the contrast preference — turning high contrast
    /// on must never swallow the orange/red alert.
    func testAlertingUrgenciesStayPillRegardlessOfHighContrast() {
        for highContrast in [false, true] {
            XCTAssertEqual(MenuLabelStyle.resolve(urgency: .warning, highContrast: highContrast),
                           .pill(.warning))
            XCTAssertEqual(MenuLabelStyle.resolve(urgency: .critical, highContrast: highContrast),
                           .pill(.critical))
        }
    }
}
