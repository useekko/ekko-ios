import SwiftUI
import UIKit

/// A controlled host that switches the same editor between Apple's current keyboard and Ekko's
/// shared clean-room plane. UI tests never compare two different apps, fields, traits, or widths.
final class KeyboardLabViewController: UIViewController {
    private let mode = UISegmentedControl(items: ["Apple", "Replica"])
    private let appearance = UISegmentedControl(items: ["Light", "Dark"])
    private let surface = UISegmentedControl(items: ["ABC", "Emoji"])
    private let editor = AppleReferenceTextView()
    private let status = UILabel()
    private var replicaInput: UIInputView?
    private var replicaHost: UIHostingController<LabReplicaKeyboard>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()
        configureView()
        installConstraints()
    }

    private func configureAppearance() {
        let requested = ProcessInfo.processInfo.environment["LAB_APPEARANCE"]
        let dark = requested == "dark"
        overrideUserInterfaceStyle = dark ? .dark : .light
        appearance.selectedSegmentIndex = dark ? 1 : 0
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "KeyboardLab"
        title.font = .systemFont(ofSize: 28, weight: .bold)

        let detail = UILabel()
        detail.text = "One field. Apple and production Ekko. Same device, appearance, and input state."
        detail.font = .systemFont(ofSize: 14)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0

        mode.selectedSegmentIndex = 0
        mode.accessibilityIdentifier = "keyboard-mode"
        mode.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        appearance.accessibilityIdentifier = "keyboard-appearance"
        appearance.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)

        surface.selectedSegmentIndex = 0
        surface.accessibilityIdentifier = "keyboard-surface"
        surface.addTarget(self, action: #selector(surfaceChanged), for: .valueChanged)

        editor.accessibilityIdentifier = "lab-editor"
        editor.font = .systemFont(ofSize: 19)
        editor.backgroundColor = .secondarySystemBackground
        editor.layer.cornerRadius = 14
        editor.layer.borderWidth = 1
        editor.layer.borderColor = UIColor.separator.cgColor
        editor.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        editor.autocorrectionType = .no
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.keyboardType = .default
        editor.returnKeyType = .default
        editor.textContentType = .none

        status.text = "APPLE REFERENCE"
        status.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        status.textColor = .secondaryLabel
        status.accessibilityIdentifier = "lab-status"

        let controls = UIStackView(arrangedSubviews: [mode, appearance, surface])
        controls.axis = .vertical
        controls.spacing = 10

        let stack = UIStackView(arrangedSubviews: [title, detail, controls, editor, status])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        stack.accessibilityIdentifier = "lab-controls"
        stack.tag = 99
    }

    private func installConstraints() {
        guard let stack = view.viewWithTag(99) else { return }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            editor.heightAnchor.constraint(equalToConstant: 112),
        ])
    }

    @objc private func modeChanged() {
        // Emoji owns a system search strip outside the keyboard view itself. Fully end the old
        // input session before installing the replica so UIKit cannot carry that strip across and
        // make the shared production surface look taller than it really is.
        editor.resignFirstResponder()
        if mode.selectedSegmentIndex == 0 {
            removeReplica()
            editor.referenceSurface = surface.selectedSegmentIndex == 1 ? .emoji : .letters
            editor.inputView = nil
            status.text = surface.selectedSegmentIndex == 1
                ? "APPLE EMOJI REFERENCE" : "APPLE REFERENCE"
        } else {
            editor.referenceSurface = .letters
            editor.inputView = makeReplica()
            status.text = surface.selectedSegmentIndex == 1
                ? "SHARED PRODUCTION EMOJI" : "SHARED PRODUCTION REPLICA"
        }
        editor.reloadInputViews()
        editor.becomeFirstResponder()
    }

    @objc private func appearanceChanged() {
        overrideUserInterfaceStyle = appearance.selectedSegmentIndex == 1 ? .dark : .light
        // Both keyboards must be recreated after a trait change; otherwise UIKit may retain the
        // material it resolved when the input view first appeared.
        if mode.selectedSegmentIndex == 1 {
            removeReplica()
            editor.inputView = makeReplica()
        }
        editor.reloadInputViews()
        if !editor.isFirstResponder { editor.becomeFirstResponder() }
    }

    @objc private func surfaceChanged() {
        guard mode.selectedSegmentIndex == 0 else {
            editor.referenceSurface = .letters
            removeReplica()
            editor.inputView = makeReplica()
            status.text = surface.selectedSegmentIndex == 1
                ? "SHARED PRODUCTION EMOJI" : "SHARED PRODUCTION REPLICA"
            editor.reloadInputViews()
            if !editor.isFirstResponder { editor.becomeFirstResponder() }
            return
        }
        editor.referenceSurface = surface.selectedSegmentIndex == 1 ? .emoji : .letters
        status.text = surface.selectedSegmentIndex == 1
            ? "APPLE EMOJI REFERENCE" : "APPLE REFERENCE"
        editor.reloadInputViews()
        if !editor.isFirstResponder { editor.becomeFirstResponder() }
    }

    private func makeReplica() -> UIInputView {
        if let replicaInput { return replicaInput }

        let input = UIInputView(
            frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: NativeKeyboardMetrics.planeHeight),
            inputViewStyle: .keyboard
        )
        input.backgroundColor = UIColor(Ink.keyBacking)
        input.accessibilityIdentifier = "replica-keyboard-plane"

        let root = LabReplicaKeyboard(
            initialPlane: surface.selectedSegmentIndex == 1 ? .emoji : .letters,
            onText: { [weak editor] text in editor?.insertText(text) },
            onBackspace: { [weak editor] in editor?.deleteBackward() },
            onNextKeyboard: { [weak self] in
                guard let self else { return }
                mode.selectedSegmentIndex = 0
                modeChanged()
            }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        // An input view is moved by UIKit into its own keyboard window. Making this hosting
        // controller a child of the app controller would leave parent and child in different
        // windows, which UIKit correctly rejects during reloadInputViews.
        input.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: input.topAnchor),
            host.view.heightAnchor.constraint(equalToConstant: NativeKeyboardMetrics.planeHeight),
        ])
        replicaInput = input
        replicaHost = host
        return input
    }

    private func removeReplica() {
        replicaHost?.view.removeFromSuperview()
        replicaHost = nil
        replicaInput = nil
    }
}

/// A simulator can remember Ekko as the last-used keyboard. The reference side must not depend on
/// that mutable global selection, so it asks UIKit for the active English system input mode.
/// Custom extension modes have no primary language and are therefore excluded.
private final class AppleReferenceTextView: UITextView {
    enum ReferenceSurface {
        case letters
        case emoji
    }

    var referenceSurface = ReferenceSurface.letters

    override var textInputMode: UITextInputMode? {
        switch referenceSurface {
        case .letters:
            return UITextInputMode.activeInputModes.first { mode in
                guard let language = mode.primaryLanguage else { return false }
                return language == "en-US" || language.hasPrefix("en-")
            } ?? super.textInputMode
        case .emoji:
            // Emoji is exposed as a normal active input mode with the public BCP-47-like language
            // value `emoji`; no private identifier or implementation detail is inspected.
            return UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" }
                ?? super.textInputMode
        }
    }
}

private struct LabReplicaKeyboard: View {
    @State private var plane: NativeKeyboardPlane
    @State private var shifted = true
    @State private var capsLock = false

    let showsInlineEmoji: Bool
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onNextKeyboard: () -> Void

    init(
        initialPlane: NativeKeyboardPlane,
        onText: @escaping (String) -> Void,
        onBackspace: @escaping () -> Void,
        onNextKeyboard: @escaping () -> Void
    ) {
        _plane = State(initialValue: initialPlane)
        showsInlineEmoji = initialPlane == .emoji
        self.onText = onText
        self.onBackspace = onBackspace
        self.onNextKeyboard = onNextKeyboard
    }

    var body: some View {
        NativeKeyPlaneView(
            plane: $plane,
            shifted: $shifted,
            capsLock: $capsLock,
            // The forced Apple reference mode deliberately hides alternate-input affordances. The
            // production view still receives `needsInputModeSwitchKey` from its controller.
            showsGlobe: false,
            // ABC parity keeps Apple's native three-key bottom row. The dedicated Emoji lab mode
            // exercises the same in-extension surface and production keeps this affordance on.
            showsEmoji: showsInlineEmoji,
            onText: { value in
                onText(value)
                if shifted && !capsLock { shifted = false }
            },
            onBackspace: onBackspace,
            onNextKeyboard: onNextKeyboard
        )
        .background(Ink.keyBacking)
    }
}
