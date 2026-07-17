import EkkoCore
import SwiftUI

/// One person, whole.
///
/// A person in Ekko has two bodies. One is a KEY — a fingerprint and a safety number, the thing that
/// actually protects you. The other is a set of ADDRESSES — @maya on Instagram, a phone on WhatsApp.
/// The product's whole claim is that these are the same person, and until this screen existed they
/// lived on different tabs and never appeared in one frame.
///
/// This screen shows the addresses and is scrupulously honest that they are not the key: connecting
/// here is an address book, and the copy says so where it cannot be missed. See docs/ACCOUNTS.md —
/// the account scaffold and the key directory are deliberately separate systems.
struct ProfileView: View {
    @Environment(EkkoEngine.self) private var engine
    @EnvironmentObject private var account: EkkoAccount

    let profile: EkkoProfile
    /// Tell the list behind us that an edge changed, so it does not go stale under a back swipe.
    var onChange: () -> Void = {}

    @State private var connection: EkkoConnection?
    @State private var socials: [EkkoSocial] = []
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var showInvite = false
    @State private var confirmDisconnect = false

    /// Where we stand with them. Everything on this screen keys off this one value.
    private enum Standing {
        case strangers
        case theyOweYouAnAnswer  // you asked
        case youOweThemAnAnswer  // they asked
        case connected
    }

    private var standing: Standing {
        guard let c = connection, let me = account.userId else { return .strangers }
        if c.status == "accepted" { return .connected }
        return c.requester == me ? .theyOweYouAnAnswer : .youOweThemAnAnswer
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                action
                addresses
                encryption
            }
            .padding(20)
            .padding(.bottom, 24)  // the floating tab bar overlays the tail of the scroll
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.bg)
        // No navigation title on purpose. The serif @handle two lines below IS the title, and a
        // nav bar repeating it verbatim is the screen talking to itself.
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
        .sheet(isPresented: $showInvite) { InviteSheet() }
        .task(id: profile.userId) { await reload() }
    }

    // MARK: - Who they are

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            PersonAvatar(handle: profile.handle, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("@\(profile.handle)")
                    .font(.display(32))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let name = profile.displayName, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.muted)
                }
            }

            standingPill
        }
    }

    @ViewBuilder private var standingPill: some View {
        switch standing {
        case .connected:
            pill("Connected", icon: "checkmark", tint: Ink.accentDeep)
        case .theyOweYouAnAnswer:
            pill("Request sent", icon: "clock", tint: Ink.muted)
        case .youOweThemAnAnswer:
            pill("Wants to connect", icon: "bell", tint: Ink.accentDeep)
        case .strangers:
            EmptyView()
        }
    }

    private func pill(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }

    // MARK: - The one thing to do next

    @ViewBuilder private var action: some View {
        switch standing {
        case .strangers:
            Button("Connect with @\(profile.handle)") {
                run { try await account.sendRequest(to: profile.userId) }
            }
            .buttonStyle(AccentButton())
            .disabled(working)

        case .youOweThemAnAnswer:
            VStack(spacing: 10) {
                Button("Accept") {
                    guard let id = connection?.id else { return }
                    run { try await account.accept(connectionId: id) }
                }
                .buttonStyle(AccentButton())
                .disabled(working)

                Button("Decline") {
                    guard let id = connection?.id else { return }
                    run { try await account.removeConnection(id: id) }
                }
                .buttonStyle(QuietButton(wide: true))
                .disabled(working)
            }

        case .theyOweYouAnAnswer:
            Button("Cancel request") {
                guard let id = connection?.id else { return }
                run { try await account.removeConnection(id: id) }
            }
            .buttonStyle(QuietButton(wide: true))
            .disabled(working)

        case .connected:
            EmptyView()
        }
    }

    // MARK: - Where they can be reached

    private var addresses: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where they can be reached").kickerStyle()

            if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if standing == .connected {
                if socials.isEmpty {
                    Text("@\(profile.handle) has not listed any apps yet.")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(listed.enumerated()), id: \.element.id) { i, entry in
                            if i > 0 { Divider().overlay(Ink.line) }
                            AddressRow(platform: entry.platform, handle: entry.handle)
                        }
                    }
                    .card(padding: 16)

                    Text("Opening a chat does not encrypt it. Ekko seals the message when you write it with the Ekko keyboard.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                locked
            }
        }
    }

    private struct Listed: Identifiable {
        let id: String
        let platform: Platform
        let handle: String
    }

    /// Rows in the registry's order rather than the server's, so the list is stable however the rows
    /// come back. A platform the registry has never heard of is dropped rather than half-drawn — the
    /// server only accepts these six (docs/ACCOUNTS.md), so there is nothing to lose here.
    private var listed: [Listed] {
        Platform.all.compactMap { p in
            socials.first { $0.platform == p.id }
                .map { Listed(id: $0.id, platform: p, handle: $0.handle) }
        }
    }

    /// The empty state that sells the connection: it says exactly what is behind the door. The
    /// server genuinely returns nothing here until the edge is accepted, so this is not theatre.
    private var locked: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 18))
                .foregroundStyle(Ink.faint)

            Text(standing == .youOweThemAnAnswer
                 ? "Accept, and you will each see where the other can be reached."
                 : "Connect with @\(profile.handle), and you will each see where the other can be reached.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("Their Instagram, WhatsApp, Telegram: whichever they chose to list. Only people they accept can see them.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    // MARK: - The honest limit

    /// The contact behind this person, if their published key is already in our vault. Matched by
    /// KEY, never by name — a name is the user's to change, a key is not.
    private var contact: Contact? {
        guard let key = peerKey, let bundle = AccountSync.bundle(of: key) else { return nil }
        return engine.contacts.first { $0.bundle == bundle }
    }

    private var peerKey: String? {
        guard let me = account.userId, let c = connection else { return nil }
        return c.peer(of: me).profile?.publicKey
    }

    private var encryption: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Encryption").kickerStyle()

            if let contact {
                // The whole point of putting the key in the profile: being connected IS being able
                // to encrypt. No invites, no QR codes, no copy-paste.
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        contact.verified ? "Verified, and encrypted" : "You can encrypt to them",
                        systemImage: contact.verified ? "checkmark.seal.fill" : "lock.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Ink.accentDeep)

                    Text(contact.verified
                         ? "You compared the safety number and it matched. Write to them with the Ekko keyboard in any app."
                         : "Their key came from their profile, so Ekko has not yet proved it is really theirs. Compare the safety number with \(profile.handle) on a call or in person, and no one can be standing in the middle.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)

                if !contact.verified {
                    NavigationLink(value: contact.id) {
                        Text("Compare safety numbers")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Ink.inkSoft)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Ink.surface, in: .rect(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Ink.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            } else if standing == .connected, peerKey == nil {
                // Connected, but nobody has ever set Ekko up for that handle — so there is no key in
                // existence to encrypt to. Say that, rather than blaming the user's setup.
                VStack(alignment: .leading, spacing: 8) {
                    Text("@\(profile.handle) has not set up Ekko yet.")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.inkSoft)

                    Text("Their account has a handle, but no device has made them an Ekko identity, so there is no key to encrypt to. Once they open Ekko and claim their handle, they appear here and you can write to them straight away.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect first.")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.inkSoft)

                    Text("Once you are connected, Ekko picks up their key from their profile and you can write to them sealed, with no invite to paste. You can also hand them your invite by any channel you like: it is a public key, safe even on one you do not trust.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)

                Button("Share your invite") { showInvite = true }
                    .buttonStyle(QuietButton(wide: true))
            }

            if standing == .connected {
                Button("Disconnect") { confirmDisconnect = true }
                    .buttonStyle(DangerButton())
                    .padding(.top, 6)
                    .confirmationDialog(
                        "Disconnect from @\(profile.handle)?",
                        isPresented: $confirmDisconnect, titleVisibility: .visible
                    ) {
                        Button("Disconnect", role: .destructive) {
                            guard let id = connection?.id else { return }
                            run { try await account.removeConnection(id: id) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("You stop seeing each other's apps. Any contact and any secure session you already have with them is untouched.")
                    }
            }
        }
    }

    // MARK: - Loading

    private func reload() async {
        guard account.isSignedIn, let me = account.userId else { return }
        do {
            connection = try await account.connections().first { c in
                let peer = c.peer(of: me)
                return peer.userId == profile.userId
            }
            // The server hands back an empty list rather than an error until the edge is accepted,
            // so asking while still strangers is cheap and tells the truth by itself.
            socials = standing == .connected ? try await account.socials(of: profile.userId) : []
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await action()
                await reload()
                // Accepting is the moment their key becomes visible to us, so pick it up NOW rather
                // than leaving the user on a screen that says "connected" while the keyboard still
                // insists it has nobody to seal to.
                await AccountSync.run(account: account, engine: engine)
                engine.reload()
                onChange()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
