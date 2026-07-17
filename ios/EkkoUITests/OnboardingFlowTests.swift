import XCTest

// Onboarding forks after the 24 words into the site's two modes: "@you, everywhere" (register with
// Apple, Google or email, THEN pick a handle) or "Off the grid" (no account, trade invites by
// hand). Both have to reach the end, and the handle road must be impossible to walk without
// registration. This drives the real app because the fork IS navigation — there is no model
// underneath it to unit-test, and a wrong `step =` compiles perfectly.
//
// The off-grid path is the one covered end to end: it is entirely local. The account path needs an
// INVITED email against the live Supabase project (registration is closed, see docs/ACCOUNTS.md),
// so it is asserted as far as a sign-in test can honestly go — the affordances exist, the handle
// claim is absent until a session exists, and backing out to the ghost road still finishes.
//
// Prerequisite: a simulator that has never seen Ekko, or there is no onboarding left to drive. The
// test fails loudly rather than skipping if the welcome screen is not there. Uninstalling the app
// is NOT enough — the identity lives in the App Group container, which outlives it:
//
//   scripts/ios-reset-sim.sh
final class OnboardingFlowTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    func testOffGridPathReachesTheEndWithoutAnAccount() throws {
        let app = XCUIApplication()
        app.launch()

        let create = app.buttons["Create a new identity"]
        XCTAssertTrue(
            create.waitForExistence(timeout: 15),
            "no welcome screen — the app is already onboarded. Uninstall it and run again.")
        create.tap()

        // The 24 words. The Continue button is dead until the acknowledgement is checked, which is
        // the one thing standing between a user and an unrecoverable identity.
        let acknowledge = app.switches["I have written these down"].firstMatch
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 10), "the backup step never appeared")
        attach("01-backup")

        let backupContinue = app.buttons["Continue"]
        XCTAssertTrue(backupContinue.exists, "no Continue on the backup step")
        XCTAssertFalse(
            backupContinue.isEnabled,
            "Continue was live before the user acknowledged the phrase")

        acknowledge.tap()
        XCTAssertTrue(backupContinue.isEnabled, "acknowledging the phrase did not arm Continue")
        backupContinue.tap()

        // --- the fork: the site's two modes, as cards ---
        let offGrid = app.buttons["Off the grid"]
        XCTAssertTrue(
            offGrid.waitForExistence(timeout: 10),
            "the mode step did not appear after the backup step")
        attach("02-mode-fork")

        // Both roads are actually on offer. A fork that only offers the account is a funnel,
        // and the product's whole claim is that you do not need one.
        let connect = app.buttons["@you, everywhere"]
        XCTAssertTrue(connect.exists, "the fork does not offer the handle road")

        // The core rule of the handle road: registration comes FIRST. No handle UI anywhere
        // before a sign-in — not on the fork, and not on the sign-in step behind it.
        XCTAssertFalse(
            app.buttons["Claim handle"].exists,
            "the fork lets you reach a handle claim without an account")

        connect.tap()
        let google = app.buttons["Continue with Google"]
        XCTAssertTrue(
            google.waitForExistence(timeout: 10),
            "the handle road did not lead to the sign-in step")
        attach("03-sign-in-gate")
        XCTAssertTrue(
            app.buttons["Email me a sign-in code"].exists,
            "the sign-in step offers no email road")
        XCTAssertTrue(
            app.buttons["Continue with Apple"].exists,
            "the sign-in step offers no Apple road")
        XCTAssertFalse(
            app.buttons["Claim handle"].exists,
            "the sign-in step shows a handle claim before any registration")

        // Back out and take the ghost road instead.
        let back = app.buttons["Back"]
        XCTAssertTrue(back.exists, "no way back from the sign-in step to the fork")
        back.tap()
        XCTAssertTrue(offGrid.waitForExistence(timeout: 10), "Back did not return to the fork")

        offGrid.tap()

        // Off-grid lands on the last step, with no account and no handle.
        let done = app.buttons["Done"]
        XCTAssertTrue(
            done.waitForExistence(timeout: 10),
            "choosing off-grid did not reach the keyboard step")
        attach("04-keyboard-step")
        done.tap()

        // …and into the app proper, with an identity that owes nothing to any server.
        let identity = app.buttons["Identity"]
        XCTAssertTrue(
            identity.waitForExistence(timeout: 10), "off-grid onboarding never reached the app")
        identity.tap()

        // The account is offered, not assumed. This is the copy an off-grid user must see.
        XCTAssertTrue(
            app.staticTexts["Connect an account"].waitForExistence(timeout: 5),
            "the Identity tab does not offer an account to an off-grid user")
        attach("05-identity-off-grid")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
