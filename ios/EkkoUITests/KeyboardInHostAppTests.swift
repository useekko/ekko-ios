import UIKit
import XCTest

// The end-to-end test that matters: the Ekko keyboard, running inside SOMEONE ELSE'S app.
//
// Unit tests cover the model against a fake text field. This covers everything only a running
// system can tell us: that the extension loads, that SwiftUI renders inside a keyboard's tight
// memory budget, that App Group access survives the extension sandbox (so the keyboard can see
// the vault the app wrote), and that manual Seal replaces the host's plaintext with ciphertext.
//
// Safari stands in for a messenger: its address bar is an ordinary text field and it exists
// everywhere.
//
// Prerequisites (both scripted):
//   scripts/ios-sim-setup.sh   registers the keyboard, the way Settings would
//   scripts/ios-seed-sim.mjs   seeds the App Group vault with an identity and one contact
final class KeyboardInHostAppTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true  // keep the screenshots even when an assertion fails
    }

    @MainActor
    func testKeyboardReplacesComposerWithCiphertext() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "Safari did not come up")

        let field =
            safari.textFields.firstMatch.exists
            ? safari.textFields.firstMatch : safari.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no text field in Safari")
        field.tap()

        // Identify Ekko by the one thing only Ekko draws: its lock chip. Matching on the LABEL
        // rather than an identifier keeps this honest — it is what a user would look at — and
        // sidesteps two XCUITest quirks: `safari.keyboards` only ever matches the SYSTEM keyboard,
        // and the chip's element type shifts around between releases.
        let ekko = safari.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label BEGINSWITH 'Sealing to' OR label == 'Not encrypting'")
            )
            .firstMatch

        let globe = safari.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(
            globe.waitForExistence(timeout: 15),
            "no globe key — is the Ekko keyboard registered? run scripts/ios-sim-setup.sh")
        attach("00-keyboard-up")

        // Cycle the globe until Ekko is the active keyboard.
        for hop in 0..<4 where !ekko.exists {
            globe.tap()
            _ = ekko.waitForExistence(timeout: 4)
            attach("01-globe-tap-\(hop + 1)")
        }
        dumpTree(safari, "tree-ekko-active")
        XCTAssertTrue(ekko.exists, "the Ekko keyboard never became active")
        attach("02-ekko-active")

        // It read the vault out of the App Group and armed the lock on the seeded contact. If the
        // entitlement were missing this would read "Not encrypting" instead.
        XCTAssertEqual(
            ekko.label, "Sealing to Mara Vance",
            "the keyboard did not load the shared vault (App Group / entitlements?)")

        // Shift starts on (sentence case), so the first cap identifies as "H" and the rest as
        // lowercase once the one-shot shift drops.
        let word = "hello"
        for letter in word.map(String.init) {
            let cap = keyCap(in: safari, named: letter)
            XCTAssertTrue(cap.exists, "no '\(letter)' key on the Ekko keyboard")
            cap.tap()
        }
        attach("03-typed-in-composer")
        XCTAssertTrue(
            (field.value as? String ?? "").localizedCaseInsensitiveContains(word),
            "plaintext did not reach the host composer")

        // Exact match: the contact chip also starts with "Sealing", but opens the picker.
        let seal = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Seal'"))
            .firstMatch
        XCTAssertTrue(
            seal.waitForExistence(timeout: 5),
            "no manual Seal action appeared")
        seal.tap()

        // The same field is replaced in place with ciphertext.
        // (A plain poll: XCTestCase's expectation API is not Sendable under Swift 6.)
        let deadline = Date().addingTimeInterval(10)
        var out = ""
        repeat {
            out = field.value as? String ?? ""
            if out.contains("EKK1") { break }
            usleep(200_000)
        } while Date() < deadline
        attach("04-sealed-into-host-field")
        XCTAssertTrue(out.contains("EKK1"), "the host field did not receive an Ekko token")
        XCTAssertFalse(
            out.localizedCaseInsensitiveContains(word), "Seal left plaintext in the host field")

        // Prove the inbound half through the actual OS paste boundary. Writing is test setup;
        // tapping UIPasteControl below is the same consent-aware handoff a person uses after Copy.
        UIPasteboard.general.string = out
        let paste = safari.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label == 'Paste copied Ekko message' OR label == 'Paste'"))
            .firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no system Paste action appeared")
        paste.tap()

        let reader = safari.staticTexts["Your sealed message"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 8), "Paste did not open the private reader")
        let plaintext = safari.staticTexts
            .matching(NSPredicate(format: "label ==[c] %@", word))
            .firstMatch
        XCTAssertTrue(
            plaintext.waitForExistence(timeout: 3),
            "the reader did not show the decrypted plaintext")
        attach("05-decrypted-reader")
        XCTAssertEqual(
            field.value as? String ?? "", out,
            "decrypting inserted plaintext into the host field")
    }

    /// A key cap, however XCUITest happens to be exposing it. SwiftUI publishes these as
    /// keyboard-key elements, which land in `.keys` / `.buttons` / `.staticTexts` depending on the
    /// traits, so try each. Letters identify by the glyph they currently DRAW, so a shifted "h" is
    /// "H".
    @MainActor
    private func keyCap(in app: XCUIApplication, named name: String) -> XCUIElement {
        for candidate in [name, name.uppercased()] {
            for query in [app.keys, app.buttons, app.staticTexts] {
                let element = query[candidate].firstMatch
                if element.exists { return element }
            }
        }
        return app.buttons[name].firstMatch
    }

    @MainActor
    private func dumpTree(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    @MainActor
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
