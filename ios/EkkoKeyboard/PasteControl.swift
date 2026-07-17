import SwiftUI
import UIKit

/// The keyboard's Decrypt control. It is built on Apple's `UIPasteControl` because that is the only
/// clipboard boundary a keyboard extension gets without a recurring "Allow Paste?" prompt or a nil
/// `UIPasteboard.general.string` read — the tap itself is the consent that hands Ekko the copied text.
///
/// iOS owns the system control's title and it is always "Paste", which reads like "insert this into
/// the field" — the opposite of what happens here (the text goes to the private reader, never the
/// host composer). Since the title can't be changed, the control runs icon-only and we put our own
/// "Decrypt" label beside it. The system icon chip stays the real, consent-bearing tap target; UI
/// tests still find it by its accessibility label.
///
/// ponytail: only the icon chip is tappable, not the whole pill. Making the word tappable too would
/// mean overlaying the system control, and its privacy safeguards can silently disable an occluded
/// control — not worth risking the one inbound-read path for a wider hit box.
struct PasteControl: View {
    var enabled: Bool
    var title: String = "Decrypt"
    var onPaste: (String?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            SystemPaste(enabled: enabled, onPaste: onPaste)
                .frame(width: 30, height: 30)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.keyboardInk)
                .accessibilityHidden(true)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity)
        .background(Ink.key.opacity(0.74), in: .rect(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Ink.keyboardLine, lineWidth: 1)
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

/// The system paste control itself — icon-only, so the iOS-owned "Paste" text does not compete with
/// our "Decrypt" label. The tap lands here, not in the messenger's composer.
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
        configuration.baseBackgroundColor = .clear
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
