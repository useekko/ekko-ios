import EkkoCore
import SwiftUI

/// A safe place to use the keyboard before a real conversation, and the way to decrypt a message
/// without leaving the app.
struct KeyboardTestView: View {
    @Environment(EkkoEngine.self) private var engine

    @State private var draft = ""
    @State private var result: EkkoEngine.Ingested?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Type here. Tap the globe key, switch to Ekko, and seal a message. Nothing you write on this screen leaves your phone.")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $draft)
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(12)
                    .background(Ink.surface, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line, lineWidth: 1))
                    .accessibilityLabel("Scratch pad")

                VStack(alignment: .leading, spacing: 14) {
                    Text("Decrypt a message").kickerStyle()

                    Text("Copy an Ekko message from any app, then bring it here.")
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Decrypt copied message", action: decrypt)
                        .buttonStyle(AccentButton())

                    if let result {
                        outcome(result)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.bg)
        .navigationTitle("Try the keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
    }

    @ViewBuilder private func outcome(_ result: EkkoEngine.Ingested) -> some View {
        switch result {
        case .message(let text, let from, let mine):
            VStack(alignment: .leading, spacing: 8) {
                Text(mine ? "You wrote" : from.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.accentDeep)
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 16)

        case .secureChannel(let with, let added):
            note(added
                ? "Secure channel open with \(with.label), who is now in your contacts."
                : "Secure channel open with \(with.label).")

        case .invited(let contact):
            note("\(contact.label) is in your contacts. You can seal messages to them now.")

        case .needMoreChunks(let have, let total):
            note("That was part \(have) of \(total). Copy the next part and paste again.")

        case .unknownSession:
            note("That message is not for this device, or the session it used is gone.")

        case .nothing:
            note("There is nothing from Ekko on the clipboard.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Ink.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 16)
    }

    private func decrypt() {
        do {
            result = try engine.ingest(UIPasteboard.general.string ?? "")
        } catch {
            result = nil
            self.error = error.localizedDescription
        }
    }
}
