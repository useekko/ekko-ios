import EkkoCore
import SwiftUI

/// The bridge that was missing: an accepted connection becomes an encrypted channel.
///
/// Until this existed, connecting with someone on the account gave you their Instagram handle and
/// nothing you could encrypt with — the keyboard would still say it had nobody to seal to, because
/// the vault had no contacts. The two halves of a person (their addresses and their key) sat in two
/// different systems and nothing carried one to the other.
///
/// Now the key rides in the profile, and this does three things whenever the app comes up:
///
///   1. PUBLISH your own public key against your handle. A public key is public — the whole product
///      already trades it over untrusted channels as a 1,600-character invite. Nothing private goes
///      up, and nothing could: `engine.invite` has no private material in it.
///   2. ADOPT the key of everyone you are connected to, as a contact.
///   3. SET UP the post-quantum session through the accepted connection, before a keyboard ever
///      writes into a messenger.
///
/// Step 2 is trust-on-first-use, and it is deliberately honest about that: the contact lands
/// UNVERIFIED, and the only thing that upgrades it is comparing the safety number with the human
/// out of band. The server saying "this is @maya's key" is the same promise Signal's server makes;
/// it is the safety number, not the server, that makes it true.
enum AccountSync {
    struct Result {
        var published = false
        var adopted: [String] = []  // handles newly encryptable
    }

    /// Idempotent and quiet: safe to call on every foreground. Failures are not surfaced — this runs
    /// behind the user's back, and a dead network must never become an alert on a screen they did
    /// not ask for.
    @MainActor
    @discardableResult
    static func run(account: EkkoAccount, engine: EkkoEngine) async -> Result {
        var result = Result()
        guard account.isSignedIn, let me = account.userId else { return result }

        do {
            // --- 1. Publish ---
            // Only once the handle exists: the key hangs off the profile row, and there is no row
            // until a handle is claimed.
            if let invite = engine.invite, let mine = try await account.myProfile() {
                if mine.publicKey != invite {
                    try await account.publishKey(invite)
                    result.published = true
                }
            }

            // --- 2 + 3. Stage setup, then adopt after acceptance ---
            let connections = try await account.connections()
            let setups = try await account.sessionSetups()
            for c in connections where c.status == "accepted" || c.requester == me {
                let peer = c.peer(of: me)
                guard let profile = peer.profile,
                      let key = profile.publicKey,
                      let bundle = bundle(of: key)
                else { continue }  // no device has made them an identity yet

                let existing = engine.contacts.first { $0.bundle == bundle }
                let provisional = existing ?? Contact(bundle: bundle, label: "@\(profile.handle)")
                let myKey = engine.identity?.fingerprint.hexString ?? ""
                let peerKey = provisional.id

                if c.requester == me {
                    // The requester stages setup while pending. RLS hides it from the other person
                    // until acceptance, which then completes pairing in the acceptor's foreground.
                    if let setup = try engine.prepareSetup(to: provisional) {
                        try await account.publishSessionSetup(
                            connectionId: c.id,
                            recipient: peer.userId,
                            senderKey: myKey,
                            recipientKey: peerKey,
                            handshake: setup)
                        try engine.markSetupPublished(to: provisional)
                    }
                }

                guard c.status == "accepted" else { continue }
                // Known contacts keep the user's label; only a newly adopted key gets the handle.
                guard let contact = existing ?? (try? engine.addContact(
                    invite: key, label: "@\(profile.handle)"))
                else { continue }  // includes our own key from another signed-in device
                if existing == nil { result.adopted.append(profile.handle) }

                if c.addressee == me, let setup = setups.last(where: {
                    $0.connectionId == c.id
                        && $0.sender == peer.userId
                        && $0.recipient == me
                        && $0.senderKey == peerKey
                        && $0.recipientKey == myKey
                }) {
                    // Re-accepting is harmless and handles requester restore/key rotation.
                    try engine.acceptSetup(setup.handshake, from: contact)
                }
            }
        } catch {
            return result  // offline, or the session lapsed. Try again next time.
        }
        return result
    }

    /// Decode an invite to the bundle it carries, so a contact can be recognised by KEY rather than
    /// by name. Names are the user's to change; keys are not.
    static func bundle(of invite: String) -> Data? {
        guard let c = Wire.classifyStandalone(invite) ?? Wire.classify(invite), c.kind == .invite
        else { return nil }
        return try? Wire.decodeBody(c.raw)
    }
}
