import SwiftUI
import UIKit

/// Apple's paste control is the reliable clipboard boundary for a keyboard extension. The tap is
/// explicit user consent, so iOS hands the copied text to Ekko without a recurring "Allow Paste?"
/// prompt and without a speculative `UIPasteboard.general.string` read returning nil.
///
/// Its visible label intentionally remains system-owned ("Paste"). The keyboard chrome explains
/// that pasting here opens an Ekko message rather than inserting it into the host composer.
struct PasteControl: UIViewRepresentable {
    var enabled: Bool
    var onPaste: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste)
    }

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor(Ink.key)
        configuration.baseForegroundColor = UIColor(Ink.keyboardInk)

        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        control.accessibilityLabel = "Paste copied Ekko message"
        control.accessibilityHint = "Decrypts the copied message without putting it in the text field"
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateUIView(_ view: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
        view.isUserInteractionEnabled = enabled
        view.alpha = enabled ? 1 : 0.42
        // UIPasteControl copies its configuration into an immutable object at initialization.
        // The UIColor values above are dynamic already, so no appearance refresh is needed here.
    }

    /// The paste lands here, not in the messenger's composer. Loading only NSString also prevents
    /// an image, URL object, or other rich clipboard payload from wandering into the decrypt path.
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
