import CoreImage.CIFilterBuiltins
import EkkoCore
import SwiftUI

/// Set once the user has seen their recovery phrase and the keyboard step. It exists because
/// `createIdentity()` flips `hasIdentity` the instant it returns, which would swap RootView to
/// HomeView while the 24 words are still on screen. Onboarding, not the vault, decides when the
/// app is set up.
let onboardedKey = "ekko.onboarded"

extension View {
    /// A single-line text input, dressed like the rest of the dark column. Same surface and hairline
    /// as the recovery-phrase editor, which rolls its own because it also needs a height ceiling.
    func field() -> some View {
        font(.system(size: 16))
            .foregroundStyle(Ink.ink)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Ink.surface, in: .rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Ink.line, lineWidth: 1))
    }

    /// The one way this app reports a thrown error.
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Ekko",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// A placeholder that reads as one. Passed as a TextField's `prompt`, because a bare TextField
/// label draws in the app's tint on a dark field, and an empty box then looks like a filled one.
/// The TextField keeps its label for VoiceOver.
func hint(_ text: String) -> Text {
    Text(text).foregroundStyle(Ink.faint)
}

struct CopyButton: View {
    let text: String
    var label = "Copy"

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(QuietButton())
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// The 24 words, numbered, in two columns. Machine output, so monospace.
struct PhraseGrid: View {
    let phrase: String

    private var words: [String] { phrase.split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
            ],
            spacing: 12
        ) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.faint)
                        .frame(minWidth: 18, alignment: .trailing)
                    Text(word)
                        .font(.machine(15))
                        .foregroundStyle(Ink.ink)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}

/// Your invite, as a QR code and as text. Shown in the Identity tab and from the empty chat list.
struct InviteCard: View {
    let invite: String

    @State private var qr: UIImage?
    @State private var qrFailed = false

    var body: some View {
        VStack(spacing: 16) {
            if let qr {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260)
                    .padding(12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("QR code of your Ekko invite")
            } else if qrFailed {
                Text("QR unavailable on this device. Copy the invite and send it as text.")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().frame(height: 120)
            }

            CopyButton(text: invite, label: "Copy invite")

            Text("An invite is your public key. It is safe to send over any channel; the recipient returns one setup response before you write.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 20)
        .task {
            guard qr == nil else { return }
            if let image = Self.makeQR(invite) { qr = image } else { qrFailed = true }
        }
    }

    private static func makeQR(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // The invite is ~1630 characters. Only correction level L leaves enough capacity for it.
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The keyboard setup instructions. The same words in onboarding and in Settings, because this is
/// the step people come back for.
struct KeyboardSetupSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(1, "Open Settings, then General, then Keyboard, then Keyboards, then Add New Keyboard. Pick **Ekko**.")
            step(2, "Tap Ekko in that list and turn on **Allow Full Access**.")

            Text("iOS will not let a keyboard read this app's secure storage unless Full Access is on, and that storage is where your keys live. The Ekko keyboard makes no network requests at all.")
                .font(.system(size: 14))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.inkSoft)
                .frame(minWidth: 26, minHeight: 26)
                .background(Ink.line, in: .circle)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A quiet pill that reads as danger. Theme.swift is shared with the keyboard, which has nothing
/// destructive in it, so this one lives with the app.
struct DangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Ink.surface, in: .rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Ink.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct OpenSettingsButton: View {
    var body: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        .buttonStyle(AccentButton())
    }
}
