import XCTest
@testable import FlexTimer

final class SessionNotifierTests: XCTestCase {
    private var posted = 0
    private var notifier: SessionNotifier!

    override func setUp() {
        posted = 0
        notifier = SessionNotifier { [self] in posted += 1 }
    }

    func testFirstObservedValueIsBaselineAndNeverPosts() {
        notifier.sessionBecame(false)   // launch already signed out
        XCTAssertEqual(posted, 0)
        notifier.sessionBecame(true)    // baseline true either
        XCTAssertEqual(posted, 0)
    }

    func testExpiryTransitionPostsOnce() {
        notifier.sessionBecame(true)
        notifier.sessionBecame(false)
        XCTAssertEqual(posted, 1)
        notifier.sessionBecame(false)   // repeated false stays silent
        notifier.sessionBecame(false)
        XCTAssertEqual(posted, 1)
    }

    func testSignInReArmsForNextExpiry() {
        notifier.sessionBecame(true)
        notifier.sessionBecame(false)   // expiry 1
        notifier.sessionBecame(true)    // signed back in
        notifier.sessionBecame(false)   // expiry 2
        XCTAssertEqual(posted, 2)
    }

    func testLaunchSignedOutThenSignInThenExpiryPostsOnce() {
        notifier.sessionBecame(false)   // baseline: signed out at launch
        notifier.sessionBecame(true)    // signed in
        notifier.sessionBecame(false)   // expired
        XCTAssertEqual(posted, 1)
    }
}
