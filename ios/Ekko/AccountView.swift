import AuthenticationServices
import EkkoCore
import SwiftUI

/// The account, which is NOT the identity. It holds your @handle and the apps you have listed. It
/// never holds a key: the 24 words do that, and they never leave the phone. Going without an account
/// (off-grid) costs you discovery and nothing else. Server contract: docs/ACCOUNTS.md.
///
/// The people you are connected TO live in the People tab. This screen is only about you.
struct AccountView: View {
    @Environment(EkkoEngine.self) private var engine
    @EnvironmentObject private var account: EkkoAccount

    @State private var profile: EkkoProfile?
    @State private var socials: [EkkoSocial] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if account.isSignedIn {
                    signedIn
                    handleSection
                    socialsSection
                    KeyBackupSection()
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Account").kickerStyle()
                        SignInCard()
                    }
                    offGrid
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.bg)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
        .task(id: account.userId) { await reload() }
    }

    // MARK: - Signed in

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Signed in").kickerStyle()

            VStack(alignment: .leading, spacing: 12) {
                Text(account.email ?? "Ekko account")
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.ink)

                Text("Your account carries your handle and your people. Your keys are not in it, and cannot be: they live in your 24 words, on this phone.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 16)

            Button("Sign out") {
                Task {
                    await account.signOut()
                    profile = nil
                    socials = []
                }
            }
            .buttonStyle(QuietButton(wide: true))
        }
    }

    // MARK: - Handle

    private var handleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your handle").kickerStyle()

            if let profile {
                VStack(alignment: .leading, spacing: 6) {
                    Text("@\(profile.handle)")
                        .font(.display(28))
                        .foregroundStyle(Ink.ink)
                    if let name = profile.displayName {
                        Text(name)
                            .font(.system(size: 14))
                            .foregroundStyle(Ink.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
            } else {
                HandleClaimCard { claimed in
                    profile = claimed
                    try? engine.setUsername(claimed.handle)
                }
            }
        }
    }

    // MARK: - Your apps

    /// Your own profile, edited in the same shape the people you connect with will read it. The row
    /// you fill in here is the row they tap to open a chat with you.
    @State private var addingPlatform: String?
    @State private var socialEntry = ""

    private var socialsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your apps").kickerStyle()

            Text("List where you can be reached. Only people you accept can see these, and this is exactly how your profile reads to them.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(Platform.all.enumerated()), id: \.element.id) { i, platform in
                    if i > 0 { Divider().overlay(Ink.line) }
                    socialRow(platform)
                }
            }
            .card(padding: 16)
        }
    }

    @ViewBuilder private func socialRow(_ platform: Platform) -> some View {
        let existing = socials.first { $0.platform == platform.id }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PlatformMark(platform: platform)

                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.name)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.ink)

                    if let existing {
                        Text(platform.display(existing.handle))
                            .font(.machine(13))
                            .foregroundStyle(Ink.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                if let existing {
                    Button {
                        run(reload: true) { try await account.removeSocial(id: existing.id) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.faint)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove your \(platform.name)")
                } else {
                    Button(addingPlatform == platform.id ? "Cancel" : "Add") {
                        addingPlatform = addingPlatform == platform.id ? nil : platform.id
                        socialEntry = ""
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ink.accentDeep)
                }
            }

            if existing == nil, addingPlatform == platform.id {
                HStack(spacing: 10) {
                    TextField(
                        "Your \(platform.name) handle",
                        text: $socialEntry,
                        prompt: hint(platform.hint)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(platform.isPhone ? .phonePad : .default)
                    .field()

                    Button("Save") {
                        run(reload: true) {
                            _ = try await account.addSocial(platform: platform.id, handle: socialEntry)
                            addingPlatform = nil
                        }
                    }
                    .buttonStyle(QuietButton())
                    .disabled(socialEntry.isEmpty || loading)
                }
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Off-grid

    private var offGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You are off-grid.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.inkSoft)

            Text("Ekko works without an account. You keep your keys, your contacts and your messages exactly as you have them. What an account adds is a handle people can find you at, instead of trading invites by hand.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    // MARK: - Loading

    private func reload() async {
        guard account.isSignedIn else {
            profile = nil
            socials = []
            return
        }
        do {
            profile = try await account.myProfile()
            socials = try await account.socials()
            // The handle is a display label the app already had a slot for, and nothing was ever
            // filling it. Keep it in step with the account. It is a name, not a key.
            if let handle = profile?.handle, engine.username != handle {
                try? engine.setUsername(handle)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(reload wants: Bool = false, _ action: @escaping () async throws -> Void) {
        loading = true
        Task { @MainActor in
            defer { loading = false }
            do {
                try await action()
                if wants { await reload() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Sign in

/// Whether this BUILD can complete Sign in with Apple. A personal (free) team cannot carry the
/// capability, so day-to-day device builds sign without it (see project.yml) and the button would
/// only ever throw. The embedded provisioning profile is the truth: present without the
/// entitlement means a dev build that cannot. The simulator and App Store builds carry no
/// readable profile here, and both CAN (the store build's App ID has the capability).
private let appleSignInAvailable: Bool = {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let text = try? String(contentsOf: url, encoding: .isoLatin1) else { return true }
    return text.contains("com.apple.developer.applesignin")
}()

/// The sign-in form itself, used in onboarding and again on the account screen. Three roads, all
/// live: Apple (native sheet, id_token grant), Google (provider on, `ekko://auth-callback`
/// allowlisted) and the emailed code. The code is 8 digits rather than only a link because a
/// one-time link is single-use and mail scanners eat them.
struct SignInCard: View {
    @EnvironmentObject private var account: EkkoAccount
    @Environment(\.colorScheme) private var scheme

    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var error: String?
    @State private var working = false
    @State private var nonce = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if appleSignInAvailable {
                SignInWithAppleButton(.continue) { request in
                    let pair = EkkoAccount.makeNonce()
                    nonce = pair.raw
                    request.requestedScopes = [.email]
                    request.nonce = pair.hashed
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else { return }
                        let raw = nonce
                        run { try await account.signInWithApple(credential: cred, nonce: raw) }
                    case .failure(let err):
                        // Closing the Apple sheet is a decision, not an error worth an alert.
                        if (err as? ASAuthorizationError)?.code == .canceled { return }
                        error = err.localizedDescription
                    }
                }
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .disabled(working)
            }

            Button {
                run { try await account.signInWithGoogle() }
            } label: {
                Label("Continue with Google", systemImage: "globe")
            }
            .buttonStyle(AccentButton())
            .disabled(working)

            HStack(spacing: 12) {
                line
                Text("or")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.faint)
                line
            }

            TextField("Email address", text: $email, prompt: hint("you@example.com"))
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .field()

            Button(sent ? "Send another code" : "Email me a sign-in code") {
                run {
                    try await account.sendMagicLink(to: email)
                    sent = true
                }
            }
            .buttonStyle(QuietButton(wide: true))
            .disabled(!email.contains("@") || working)

            if sent {
                Text("Check your mail. Tap the link, or type the 8 digit code here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Sign-in code", text: $code, prompt: hint("8 digit code"))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.machine(16))
                    .field()

                Button("Sign in") {
                    run { try await account.verifyCode(email: email, code: code) }
                }
                .buttonStyle(AccentButton())
                .disabled(code.isEmpty || working)
            }

            if working {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .errorAlert($error)
    }

    private var line: some View {
        Rectangle()
            .fill(Ink.line)
            .frame(height: 1)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do { try await action() }
            catch is CancellationError { }
            catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
                // The user closed the Google sheet. Not an error worth an alert.
            }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Key backup

/// Opt-in encrypted backup of the identity and the contact list.
///
/// The passphrase is GENERATED, six words, and shown once. That is not a UX flourish — it is the
/// security model. PBKDF2 is fast, so a passphrase a human invents is the weak link in the whole
/// design; six random words are not. The "use my own" escape hatch exists because people will
/// demand it, and it is the one path here that can actually be brute-forced.
struct KeyBackupSection: View {
    @Environment(EkkoEngine.self) private var engine
    @EnvironmentObject private var account: EkkoAccount

    @State private var existing: (blob: Backup.Blob, updatedAt: Date?)?
    @State private var loaded = false
    @State private var phase: Phase = .idle
    @State private var custom = ""
    @State private var useCustom = false
    @State private var written = false
    @State private var error: String?
    @State private var working = false
    @State private var confirmRemove = false

    private enum Phase: Equatable {
        case idle
        case showingPassphrase(String)
        case done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Key backup").kickerStyle()

            switch phase {
            case .showingPassphrase(let pass): passphraseStep(pass)
            case .done: doneCard
            case .idle: idleCard
            }
        }
        .errorAlert($error)
        .task(id: account.userId) { await load() }
    }

    // MARK: States

    @ViewBuilder private var idleCard: some View {
        Text("Ekko can keep an encrypted copy of your identity and contacts, so a new phone is a sign-in instead of typing 24 words. It is locked with a passphrase that never leaves this device. We store the locked copy and cannot open it.")
            .font(.system(size: 15))
            .foregroundStyle(Ink.muted)
            .fixedSize(horizontal: false, vertical: true)

        if !loaded {
            ProgressView().frame(maxWidth: .infinity)
        } else if let stored = existing {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    stored.updatedAt.map { "Backed up \($0.formatted(.relative(presentation: .named)))" }
                        ?? "Backed up",
                    systemImage: "checkmark.shield")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.accentDeep)

                Text("Only the passphrase you saved can open it. Lose that and this copy is scrap, but your 24 words still work.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 16)

            Button("Back up again") { begin() }
                .buttonStyle(QuietButton(wide: true))
                .disabled(working)

            Button("Remove the copy from Ekko") { confirmRemove = true }
                .buttonStyle(DangerButton())
                .confirmationDialog(
                    "Remove the backup?", isPresented: $confirmRemove, titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        run { try await account.deleteKeyBackup(); existing = nil }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The encrypted copy is deleted from Ekko. Your keys stay on this phone, and your 24 words still restore them.")
                }
        } else {
            optOutNote

            Button("Back up my keys") { begin() }
                .buttonStyle(AccentButton())
                .disabled(working || !engine.hasIdentity)
        }
    }

    private var optOutNote: some View {
        Text("You do not have to. Without a backup, your 24 words are the only way to your identity, which is exactly how Ekko works today.")
            .font(.system(size: 13))
            .foregroundStyle(Ink.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func passphraseStep(_ generated: String) -> some View {
        Text("Save this passphrase")
            .font(.display(24))
            .foregroundStyle(Ink.ink)

        Text("It is the only thing that opens your backup. Ekko does not have it and cannot reset it. Put it in your password manager.")
            .font(.system(size: 15))
            .foregroundStyle(Ink.muted)
            .fixedSize(horizontal: false, vertical: true)

        if useCustom {
            SecureField("Your own passphrase", text: $custom, prompt: hint("at least \(Backup.minPassphraseLength) characters"))
                .field()

            Text("A passphrase you invent is the one part of this an attacker can guess at. Six random words are stronger than anything memorable.")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(generated)
                .font(.machine(17))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
                .accessibilityLabel("Backup passphrase: \(generated)")

            CopyButton(text: generated, label: "Copy passphrase")
        }

        Toggle(isOn: $useCustom) {
            Text("Use my own passphrase instead")
                .font(.system(size: 14))
                .foregroundStyle(Ink.inkSoft)
        }
        .toggleStyle(.switch)
        .tint(Ink.accent)

        Toggle(isOn: $written) {
            Text("I have saved it somewhere safe")
                .font(.system(size: 15))
                .foregroundStyle(Ink.inkSoft)
        }
        .toggleStyle(.switch)
        .tint(Ink.accent)

        Button("Encrypt and upload") {
            let pass = useCustom ? custom : generated
            run {
                let blob = try engine.sealBackup(passphrase: pass)
                try await account.saveKeyBackup(blob)
                phase = .done
                await load()
            }
        }
        .buttonStyle(AccentButton())
        .disabled(!canUpload(generated) || working)
        .opacity(canUpload(generated) ? 1 : 0.45)

        Button("Cancel") { phase = .idle }
            .buttonStyle(QuietButton(wide: true))

        if working { ProgressView().frame(maxWidth: .infinity) }
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Encrypted and stored.", systemImage: "checkmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(Ink.accentDeep)

            Text("Sign in on another device and your identity and contacts come back, once you give it the passphrase.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    private func canUpload(_ generated: String) -> Bool {
        guard written else { return false }
        return useCustom ? custom.count >= Backup.minPassphraseLength : !generated.isEmpty
    }

    private func begin() {
        custom = ""
        useCustom = false
        written = false
        phase = .showingPassphrase(Backup.generatePassphrase())
    }

    private func load() async {
        guard account.isSignedIn else {
            existing = nil
            loaded = true
            return
        }
        do { existing = try await account.keyBackup() } catch { existing = nil }
        loaded = true
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Handle claim

/// Claiming the handle, in onboarding and again on the account screen if it was skipped there.
struct HandleClaimCard: View {
    @EnvironmentObject private var account: EkkoAccount
    let onClaimed: (EkkoProfile) -> Void

    @State private var entry = ""
    @State private var error: String?
    @State private var working = false

    /// Mirrors the server's grammar (`^[a-z0-9_]{3,20}$`) so the button is dead before the round
    /// trip rather than after it. The server is still the enforcement; this only saves a round trip.
    /// The ASCII gate goes first on purpose: `isNumber` alone is true for "٣" and every other
    /// non-ASCII digit, which the server would then reject.
    private var valid: Bool {
        let h = entry.lowercased()
        return (3...20).contains(h.count)
            && h.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Three to twenty characters: letters, numbers and underscores. First claim wins, and you can change it later.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("@")
                    .font(.display(20))
                    .foregroundStyle(Ink.faint)
                TextField("Handle", text: $entry, prompt: hint("handle"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .field()

            Button("Claim handle") {
                working = true
                Task { @MainActor in
                    defer { working = false }
                    do { onClaimed(try await account.claimHandle(entry.lowercased())) }
                    catch { self.error = error.localizedDescription }
                }
            }
            .buttonStyle(AccentButton())
            .disabled(!valid || working)
            .opacity(valid ? 1 : 0.45)
        }
        .errorAlert($error)
    }
}

