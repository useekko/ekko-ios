import EkkoCore
import SwiftUI
import UIKit

// The Ekko keyboard: an overlay that works inside EVERY messenger's native app, because iOS has
// no other way to reach inside one. It is the iOS answer to the browser extension's content
// script.
//
// It needs Full Access for one reason: iOS forbids a keyboard from reading its App Group
// container without it, and the vault (the keys) lives there. The keyboard makes no network
// requests of any kind — directory lookups happen in the app, never here.

final class KeyboardViewController: UIInputViewController, HostTextField {
    /// One compact state bar (42) + hairline + measured key plane (227). The private reader uses
    /// the same envelope; Emoji expands to its independently measured native 399pt surface.
    private static let composeHeight: CGFloat = 270

    private let model = KeyboardModel()
    private var hosting: UIHostingController<KeyboardView>?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.start(host: self)

        let root = KeyboardView(
            model: model,
            showsGlobe: needsInputModeSwitchKey,
            onHeightChange: { [weak self] height in self?.setKeyboardHeight(height) }
        )
        let hc = UIHostingController(rootView: root)
        hc.view.backgroundColor = .clear
        addChild(hc)
        view.addSubview(hc.view)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hc.didMove(toParent: self)
        hosting = hc

        // Without this the input view collapses to the system default height and clips our chrome.
        let h = view.heightAnchor.constraint(equalToConstant: Self.composeHeight)
        h.priority = .required - 1
        h.isActive = true
        heightConstraint = h
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The app (or a previous keyboard session) may have changed the vault under us.
        model.reloadFromDisk()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Do not leave opened plaintext waiting when the user switches apps or keyboards.
        model.hideSensitiveContent()
    }

    /// Fires whenever the host's text field changes — including when the host CLEARS it after the
    /// user taps send. That is the signal the send queue advances on.
    override func textDidChange(_ textInput: UITextInput?) {
        model.hostTextChanged()
    }

    // MARK: - HostTextField

    var textBefore: String { textDocumentProxy.documentContextBeforeInput ?? "" }
    var textAfter: String { textDocumentProxy.documentContextAfterInput ?? "" }
    var selectedText: String { textDocumentProxy.selectedText ?? "" }

    func insert(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    func moveCursor(by offset: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
    }
    func nextKeyboard() { advanceToNextInputMode() }

    private func setKeyboardHeight(_ height: CGFloat) {
        guard let heightConstraint, abs(heightConstraint.constant - height) > 0.5 else { return }
        heightConstraint.constant = height
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.view.superview?.layoutIfNeeded()
        }
    }
}
