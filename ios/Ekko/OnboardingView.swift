import EkkoCore
import SwiftUI

struct OnboardingView: View {
    @Environment(EkkoEngine.self) private var engine
    @EnvironmentObject private var account: EkkoAccount
    @AppStorage(onboardedKey) private var onboarded = false

    private enum Step { case welcome, restore, restoreFromAccount, backup, mode, signIn, handle, keyboard }

    @State private var step: Step = .welcome
    @State private var phrase = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            Ink.bg.ignoresSafeArea()

            // minHeight, not height: a short step centres itself, a long one (or a large Dynamic
            // Type setting) grows past the screen and scrolls instead of clipping.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        switch step {
                        case .welcome: welcome
                        case .restore: RestoreStep(onRestored: { step = .mode })
                        case .restoreFromAccount:
                            AccountRestoreStep(
                                onRestored: { step = .keyboard },
                                onNoBackup: { step = .welcome })
                        case .backup: backup
                        case .mode:
                            ModeStep(
                                onConnect: { step = account.isSignedIn ? .handle : .signIn },
                                onOffGrid: { step = .keyboard })
                        case .signIn:
                            SignInStep(onBack: { step = .mode }, onSignedIn: { step = .handle })
                        case .handle: HandleStep(onDone: { step = .keyboard })
                        case .keyboard: keyboard
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
        .errorAlert($error)
        .onAppear {
            // An identity that exists while onboarding is unfinished means the app died between
            // creating the key and showing the words. Put them back in front of the user.
            if step == .welcome, engine.hasIdentity, let stored = engine.mnemonic {
                phrase = stored
                step = .backup
            }
        }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: 20) {
            EchoMark()
                .padding(.bottom, 8)

            Text("Ekko")
                .font(.display(44, .semibold))
                .foregroundStyle(Ink.ink)

            Text("Say it like no one is listening.")
                .font(.display(20))
                .foregroundStyle(Ink.inkSoft)
                .multilineTextAlignment(.center)

            Text("Post-quantum encrypted messages, inside the apps you already use.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            VStack(spacing: 12) {
                Button("Create a new identity") {
                    do {
                        phrase = try engine.createIdentity()
                        step = .backup
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(AccentButton())

                Button("I already have a recovery phrase") { step = .restore }
                    .buttonStyle(QuietButton())

                // The reason the backup feature exists: a new phone should be a sign-in, not 24
                // words typed on a touchscreen.
                Button("Restore from my Ekko account") { step = .restoreFromAccount }
                    .buttonStyle(QuietButton())
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Back up the phrase

    private var backup: some View {
        BackupStep(phrase: phrase, onContinue: { step = .mode })
    }

    // MARK: - Keyboard

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Last step").kickerStyle()

            Text("Turn on the Ekko keyboard")
                .font(.display(30))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("The keyboard is how you seal and read messages inside WhatsApp, Telegram, Instagram and the rest.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            KeyboardSetupSteps()
                .card(padding: 20)

            VStack(spacing: 12) {
                OpenSettingsButton()

                Button("Done") { onboarded = true }
                    .buttonStyle(QuietButton(wide: true))
            }

            Text("You can skip this. Without the keyboard, Ekko still holds your identity and your contacts, and the steps are waiting for you in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Steps

private struct BackupStep: View {
    let phrase: String
    let onContinue: () -> Void

    @State private var written = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Your recovery phrase").kickerStyle()

            Text("Write these 24 words down")
                .font(.display(30))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("This phrase is your identity. Anyone who has it can read your messages. Ekko cannot recover it for you, and neither can anyone else.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            PhraseGrid(phrase: phrase)

            CopyButton(text: phrase, label: "Copy phrase")

            Toggle(isOn: $written) {
                Text("I have written these down")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.inkSoft)
            }
            .toggleStyle(CheckboxToggle())

            Button("Continue", action: onContinue)
                .buttonStyle(AccentButton())
                .disabled(!written)
                .opacity(written ? 1 : 0.45)
        }
    }
}

/// New phone, old identity: sign in, give the backup passphrase, and your keys and your people come
/// back. The server handed us ciphertext and could not have done otherwise — the passphrase is what
/// opens it, and it never went anywhere near a wire.
private struct AccountRestoreStep: View {
    @Environment(EkkoEngine.self) private var engine
    @EnvironmentObject private var account: EkkoAccount
    let onRestored: () -> Void
    let onNoBackup: () -> Void

    @State private var blob: Backup.Blob?
    @State private var looked = false
    @State private var passphrase = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Restore").kickerStyle()

            Text("Bring your identity back")
                .font(.display(30))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !account.isSignedIn {
                Text("Sign in to the account that holds your encrypted backup.")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)

                SignInCard()
            } else if !looked {
                ProgressView().frame(maxWidth: .infinity)
            } else if blob != nil {
                Text("Found an encrypted backup on your account. Give it the passphrase you saved and it opens here, on this phone.")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("Backup passphrase", text: $passphrase, prompt: hint("your six words"))
                    .field()

                Button("Restore") { restore() }
                    .buttonStyle(AccentButton())
                    .disabled(passphrase.isEmpty || working)

                if working { ProgressView().frame(maxWidth: .infinity) }
            } else {
                Text("This account has no backup on it. If your identity lives on another device, its 24 words will bring it back here.")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Back", action: onNoBackup)
                    .buttonStyle(AccentButton())
            }
        }
        .errorAlert($error)
        .task(id: account.userId) {
            guard account.isSignedIn else { return }
            looked = false
            do { blob = try await account.keyBackup()?.blob } catch { self.error = error.localizedDescription }
            looked = true
        }
    }

    private func restore() {
        guard let blob else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try engine.restore(backup: blob, passphrase: passphrase)
                onRestored()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The fork, the same one the site leads with: claim a handle, or stay a ghost. Both are real and
/// both finish onboarding. The handle road passes through registration first — a handle lives on
/// an account, and there is deliberately no way to pick one without signing in. The account buys
/// discovery and nothing else: the identity is already derived, from the 24 words, on this phone,
/// and choosing off-grid here costs no crypto at all.
private struct ModeStep: View {
    let onConnect: () -> Void
    let onOffGrid: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Two ways to use it").kickerStyle()

            Text("Claim a handle. Or stay a ghost.")
                .font(.display(30))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)

            ModeCard(
                title: "@you, everywhere",
                detail: "Claim your handle once, link your socials, and add friends everywhere. They find your public key automatically. Every app you share becomes a sealed channel.",
                note: "Sign in with Apple, Google or email",
                action: onConnect)

            ModeCard(
                title: "Off the grid",
                detail: "No handle, no sign-in, nothing to join. Your keys stay on this phone and you trade invites directly with the people you trust. We never even learn you exist.",
                note: "No account, ever",
                action: onOffGrid)

            Text("Either way your keys never leave this phone, and you can connect an account or go dark later, from the Identity tab.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One of the two roads, as a tappable card: serif title, honest body, one quiet line about what
/// the road costs.
private struct ModeCard: View {
    let title: String
    let detail: String
    let note: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.display(21))
                        .foregroundStyle(Ink.ink)

                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(note)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.accentDeep)
                }
                .multilineTextAlignment(.leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .card(padding: 18)
        .accessibilityLabel(title)
        .accessibilityHint(note)
    }
}

/// Registration, and only registration: the handle screen is behind it. Apple, Google, or the
/// emailed code — all three land on the same account, because Supabase links by email.
private struct SignInStep: View {
    @EnvironmentObject private var account: EkkoAccount
    let onBack: () -> Void
    let onSignedIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Your handle").kickerStyle()

            Text("First, an account")
                .font(.display(30))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("A handle needs somewhere to live. Your account holds it, and the people you connect with. It never holds your keys. Those are your 24 words, and they stay on this phone.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            SignInCard()

            Button("Back", action: onBack)
                .buttonStyle(QuietButton(wide: true))
        }
        .onAppear { if account.isSignedIn { onSignedIn() } }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { onSignedIn() }
        }
    }
}

/// The payoff of registering: the handle. Reachable only signed in.
private struct HandleStep: View {
    @Environment(EkkoEngine.self) private var engine
    @EnvironmentObject private var account: EkkoAccount
    let onDone: () -> Void

    @State private var profile: EkkoProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Your handle").kickerStyle()

            Text("Pick your handle")
                .font(.display(30))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("People find you at your handle instead of trading invites by hand. First claim wins.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let profile {
                Label("You are @\(profile.handle).", systemImage: "checkmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.accentDeep)

                Button("Continue", action: onDone)
                    .buttonStyle(AccentButton())
            } else {
                HandleClaimCard { claimed in
                    profile = claimed
                    try? engine.setUsername(claimed.handle)
                }

                Button("Skip for now", action: onDone)
                    .buttonStyle(QuietButton(wide: true))
            }
        }
        // A restored identity may already own a handle; show it instead of a claim form that
        // could only answer "taken".
        .task {
            guard profile == nil, let mine = try? await account.myProfile() else { return }
            profile = mine
            if engine.username != mine.handle { try? engine.setUsername(mine.handle) }
        }
    }
}

private struct RestoreStep: View {
    @Environment(EkkoEngine.self) private var engine
    let onRestored: () -> Void

    @State private var entry = ""
    @State private var error: String?

    private var words: Int { entry.split(whereSeparator: \.isWhitespace).count }
    private var valid: Bool { Recovery.isValidMnemonic(entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Restore").kickerStyle()

            Text("Enter your recovery phrase")
                .font(.display(30))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("The same 24 words give you the same identity you already have in the Ekko browser extension, with the same contacts able to reach you. Nothing is sent anywhere. The words are turned into your keys on this phone.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $entry)
                .font(.machine(15))
                .foregroundStyle(Ink.ink)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // A TextEditor is greedy, and the centred container would let it eat the screen.
                // It scrolls its own text, so a ceiling costs the user nothing.
                .frame(minHeight: 150, maxHeight: 260)
                .padding(10)
                .background(Ink.surface, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line, lineWidth: 1))
                .accessibilityLabel("Recovery phrase")

            status

            Button("Restore identity") {
                do {
                    try engine.importIdentity(mnemonic: entry)
                    onRestored()
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .buttonStyle(AccentButton())
            .disabled(!valid)
            .opacity(valid ? 1 : 0.45)
        }
        .errorAlert($error)
    }

    @ViewBuilder private var status: some View {
        if valid {
            Label("This phrase is valid.", systemImage: "checkmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(Ink.accentDeep)
        } else if words >= 24 {
            Label("Those words are not a valid recovery phrase. Check the spelling and the order.", systemImage: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(words == 0 ? "24 words, in order, separated by spaces." : "\(words) of 24 words.")
                .font(.system(size: 14))
                .foregroundStyle(Ink.faint)
        }
    }
}

/// A checkbox, because a switch reads as a setting and this is an acknowledgement.
private struct CheckboxToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(configuration.isOn ? Ink.accentDeep : Ink.faint)
                configuration.label
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The echo: rings leaving a sealed centre. Decoration, so it is hidden from VoiceOver.
private struct EchoMark: View {
    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .strokeBorder(Ink.accent.opacity(0.30 - Double(i) * 0.09), lineWidth: 1)
                    .frame(width: 78 + CGFloat(i) * 46, height: 78 + CGFloat(i) * 46)
            }
            Image(systemName: "lock.fill")
                .font(.system(size: 24))
                .foregroundStyle(Ink.accent)
        }
        .frame(height: 174)
        .accessibilityHidden(true)
    }
}
