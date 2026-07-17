import XCTest

// The Safari launcher's entire job is to hand off to Safari with Ekko live in the page — because a
// home-screen "web app" runs in a standalone WebKit with NO extensions, while a Safari tab has them.
// So the test that matters is not "the button renders" but "tapping it actually foregrounds Safari."
// If this passes, the one thing the feature promises is true.
//
// Self-contained: drives onboarding off-grid if the app is fresh, so it survives scripts/ios-reset-sim.sh.
final class SafariLauncherTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    func testTappingAMessengerOpensSafari() throws {
        let app = XCUIApplication()
        app.launch()

        reachHome(app)

        app.buttons["Settings"].tap()

        // Key off the launcher row's explicit accessibility label, not the section kicker (which is
        // rendered uppercase by kickerStyle, so it reads "OPEN IN SAFARI" to XCUITest).
        let instagram = app.buttons["Open Instagram in Safari"]
        XCTAssertTrue(
            instagram.waitForExistence(timeout: 5),
            "the Safari launcher is missing from Settings")
        attach(app, "01-launcher")
        instagram.tap()

        // The hand-off itself: Safari must come to the foreground. This is what a home-screen web
        // app could never do — and the reason the launcher exists.
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(
            safari.wait(for: .runningForeground, timeout: 15),
            "tapping Instagram did not open Safari")
        attach(app, "02-safari-foreground")
    }

    /// Get past onboarding to the tab bar, whatever state the app launched in. Mirrors the sequence
    /// proven in OnboardingFlowTests (welcome -> backup gate -> off-grid -> keyboard).
    private func reachHome(_ app: XCUIApplication) {
        if app.buttons["Settings"].waitForExistence(timeout: 4) { return } // already onboarded

        let create = app.buttons["Create a new identity"]
        guard create.waitForExistence(timeout: 6) else {
            XCTFail("neither the app nor the welcome screen appeared")
            return
        }
        create.tap()

        let ack = app.switches["I have written these down"].firstMatch
        XCTAssertTrue(ack.waitForExistence(timeout: 10), "backup step never appeared")
        ack.tap()

        let cont = app.buttons["Continue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 5), "no Continue after acknowledging the phrase")
        XCTAssertTrue(cont.isEnabled, "Continue never enabled after acknowledging")
        cont.tap()

        let offGrid = app.buttons["Use Ekko off-grid"]
        XCTAssertTrue(offGrid.waitForExistence(timeout: 10), "account fork never appeared")
        offGrid.tap()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "keyboard step never appeared")
        done.tap()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10), "never reached the app")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
