import SwiftUI
import UIKit

/// The keyboard's Decrypt control. It is built on Apple's `UIPasteControl` because that is the only
/// clipboard boundary a keyboard extension gets without a recurring "Allow Paste?" prompt or a nil
/// `UIPasteboard.general.string` read — the tap itself is the consent that hands Ekko the copied text.
///
/// iOS owns the system control's title and it is always "Paste", which reads like "insert this into
/// the field" — the opposite of what happens here (the text goes to the private reader, never the
/// host composer). Since the title can't be changed, the control runs icon-only (a filled capsule
/// styled through its own configuration) and we set our own "Decrypt" label beside it as a caption.
///
/// The chip IS the button and the whole chip is tappable: nothing is layered over the control — no
/// SwiftUI `.overlay` (a Shape overlay is hit-testable across its frame and would steal the tap) and
/// no obscuring view (which iOS can treat as tampering and disable the paste control). The caption
/// sits next to the chip, never on top of it.
struct PasteControl: View {
    var enabled: Bool
    var title: String = "Decrypt"
    var onPaste: (String?) -> Void

    var body: some View {
        HStack(spacing: 7) {
            SystemPaste(enabled: enabled, onPaste: onPaste)
                .frame(width: 56, height: 34)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.keyboardInk)
                .accessibilityHidden(true)
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

/// The system paste control itself — icon-only, so the iOS-owned "Paste" text does not compete with
/// our "Decrypt" caption. Styling lives on its `Configuration`, so the control draws its own filled
/// chip with nothing on top to intercept the tap. The tap lands here, not in the messenger's composer.
private struct SystemPaste: UIViewRepresentable {
    var enabled: Bool
    var onPaste: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste)
    }

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor(Ink.key)
        configuration.baseForegroundColor = UIColor(Ink.keyboardInk)

        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        control.accessibilityLabel = "Decrypt copied Ekko message"
        control.accessibilityHint = "Opens the copied message in the reader without putting it in the text field"
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateUIView(_ view: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
        view.isUserInteractionEnabled = enabled
    }

    /// Loading only NSString prevents an image, URL object, or other rich clipboard payload from
    /// wandering into the decrypt path.
    final class Coordinator: UIResponder {
        var onPaste: (String?) -> Void

        init(onPaste: @escaping (String?) -> Void) {
            self.onPaste = onPaste
            super.init()
            pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        }

        override func paste(itemProviders: [NSItemProvider]) {
            guard
                let provider = itemProviders.first(where: {
                    $0.canLoadObject(ofClass: NSString.self)
                })
            else {
                onPaste(nil)
                return
            }

            provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                let copied = value as? String
                Task { @MainActor [weak self] in
                    self?.onPaste(copied)
                }
            }
        }
    }
}
