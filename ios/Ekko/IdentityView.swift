import EkkoCore
import SwiftUI

struct IdentityView: View {
    @Environment(EkkoEngine.self) private var engine
    @EnvironmentObject private var account: EkkoAccount

    @State private var confirmReveal = false
    @State private var showPhrase = false

    private var fingerprint: String? {
        engine.identity.map { EkkoCrypto.fingerprintHex($0.fingerprint) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    you
                    accountLink
                    invite
                    recovery
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.bg)
            .navigationTitle("Identity")
        }
        .sheet(isPresented: $showPhrase) { PhraseSheet() }
    }

    private var you: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You").kickerStyle()

            if let username = engine.username, !username.isEmpty {
                Text("@\(username)")
                    .font(.display(30))
                    .foregroundStyle(Ink.ink)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Fingerprint")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.muted)

                if let fingerprint {
                    Text(fingerprint)
                        .font(.machine(14))
                        .foregroundStyle(Ink.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Your fingerprint, \(fingerprint)")
                } else {
                    Text("No identity on this phone.")
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Text("The short form of your public key. A contact sees the same digits next to your name.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The account lives one tap away rather than on this screen, because this screen is about the
    /// thing that cannot be signed out of.
    private var accountLink: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account").kickerStyle()

            NavigationLink {
                AccountView()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.isSignedIn ? (account.email ?? "Ekko account") : "Connect an account")
                            .font(.system(size: 16))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)

                        Text(account.isSignedIn
                             ? "Your handle, your apps, your encrypted backup."
                             : "A handle people can find you at. Ekko works without one.")
                            .font(.system(size: 13))
                            .foregroundStyle(Ink.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
            }
            .buttonStyle(.plain)
        }
    }

    private var invite: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your invite").kickerStyle()

            if let invite = engine.invite {
                InviteCard(invite: invite)
            } else {
                Text("An invite appears once this phone has an identity.")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.muted)
            }
        }
    }

    private var recovery: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recovery").kickerStyle()

            Button {
                confirmReveal = true
            } label: {
                HStack {
                    Text("Reveal recovery phrase")
                        .font(.system(size: 16))
                        .foregroundStyle(Ink.ink)
                    Spacer(minLength: 12)
                    Image(systemName: "eye")
                        .foregroundStyle(Ink.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Reveal your recovery phrase?",
                isPresented: $confirmReveal,
                titleVisibility: .visible
            ) {
                Button("Reveal") { showPhrase = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The 24 words will be on your screen. Anyone who reads them, or photographs them, becomes you. Make sure no one is watching.")
            }

            Text("These 24 words restore this identity on another device, including the Ekko browser extension.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PhraseSheet: View {
    @Environment(EkkoEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("This phrase is your identity. Anyone who has it can read your messages. Ekko cannot recover it for you.")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let phrase = engine.mnemonic {
                        PhraseGrid(phrase: phrase)
                        CopyButton(text: phrase, label: "Copy phrase")
                    } else {
                        Text("This identity was restored without storing its phrase, so there is nothing to show.")
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.bg)
            .navigationTitle("Recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
