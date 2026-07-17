// EkkoAccountClient.swift — self-contained client for the Ekko account backend.
// Drag this ONE file into the app target; zero dependencies (URLSession,
// ASWebAuthenticationSession, Keychain). Server contract + curl reference:
// docs/ACCOUNTS.md. Registration is open during the public alpha.
//
// Wiring:
//   1. Target > Info > URL Types: add URL scheme "ekko" (needed for both the
//      ASWebAuthenticationSession Google callback and the magic-link deep link).
//   2. @StateObject var account = EkkoAccount() at the app root, pass via
//      .environmentObject, and add:
//        .onOpenURL { url in try? account.adoptSession(fromCallback: url) }
//   3. Sign in: try await account.signInWithGoogle()
//      or       try await account.sendMagicLink(to: email)   // then user taps link,
//               try await account.verifyCode(email: email, code: "12345678") // or code
//
// The Supabase URL and anon key are public by design (they ship inside the web page
// too); row-level security is the enforcement and the session JWT is the identity.

import AuthenticationServices
import CryptoKit
import EkkoCore
import Foundation
import UIKit

// MARK: - Models

struct EkkoSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

struct EkkoProfile: Codable, Identifiable, Hashable {
    let userId: String
    var handle: String
    var displayName: String?
    /// Their PUBLIC key, as the same `EKK1I:` invite you would otherwise paste by hand. Public by
    /// nature — it is safe on a channel you do not trust — which is the only reason it can sit on a
    /// server at all. nil means that account has a handle but no device has made an identity for it,
    /// so there is nothing anyone could encrypt to.
    var publicKey: String?
    var id: String { userId }
}

struct EkkoConnection: Codable, Identifiable, Hashable {
    struct Peer: Codable, Hashable {
        let handle: String
        let displayName: String?
        let publicKey: String?
    }

    let id: String
    var status: String // "pending" | "accepted"
    let requester: String
    let addressee: String
    // Embedded by PostgREST on list calls; absent on write representations.
    let requesterProfile: Peer?
    let addresseeProfile: Peer?

    func peer(of myUserId: String) -> (userId: String, profile: Peer?) {
        requester == myUserId ? (addressee, addresseeProfile) : (requester, requesterProfile)
    }
}

/// Public handshake delivery for one accepted connection. The server can route this token but
/// cannot derive the session keys inside it; ML-KEM decapsulation happens in EkkoCore on-device.
struct EkkoSessionSetup: Codable, Hashable {
    let connectionId: String
    let sender: String
    let recipient: String
    let senderKey: String
    let recipientKey: String
    let handshake: String
}

struct EkkoSocial: Codable, Identifiable, Hashable {
    let id: String
    let platform: String // instagram | telegram | whatsapp | messenger | x | discord
    let handle: String
}

extension Backup.Blob {
    /// The envelope as a plain dictionary, for JSONSerialization to post. Spelled out rather than
    /// round-tripped through JSONEncoder so the field names on the wire are impossible to drift
    /// away from the ones the TypeScript core writes and reads.
    var asJSON: [String: Any] {
        ["v": v, "kdf": kdf, "iter": iter, "salt": salt, "nonce": nonce, "ct": ct]
    }
}

enum EkkoError: LocalizedError {
    case notSignedIn
    case inviteOnly
    case expiredOrInvalid
    case conflict // duplicate handle / request / social
    case notPermitted // RLS refused: empty representation or 401/403
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .inviteOnly: return "Sign-up is temporarily unavailable."
        case .expiredOrInvalid: return "That link or code expired. Request a fresh one."
        case .conflict: return "Already exists."
        case .notPermitted: return "Not allowed."
        case .server(let code, let msg): return "Server error \(code): \(msg)"
        }
    }
}

// MARK: - Client

@MainActor
final class EkkoAccount: ObservableObject {
    static let supabaseURL = URL(string: "https://hkcohnjgyutarjoongbb.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhrY29obmpneXV0YXJqb29uZ2JiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM2OTQ3MzEsImV4cCI6MjA5OTI3MDczMX0.vjSghWu4_DxHCJqsHCEthPfn-7FXvVXMp6vSZA-BxRI"
    static let callbackScheme = "ekko"
    static let callback = "ekko://auth-callback"

    @Published private(set) var session: EkkoSession?

    var isSignedIn: Bool { session != nil }
    var userId: String? { claims?["sub"] as? String }
    var email: String? { claims?["email"] as? String }
    private var claims: [String: Any]? { session.flatMap { Self.jwtClaims($0.accessToken) } }

    private var webAuthSession: ASWebAuthenticationSession?
    private let presenter = WebAuthPresenter()

    init() {
        session = Keychain.loadSession()
    }

    // MARK: Sign in

    /// Full Google round-trip in a system auth sheet. Throws on user cancel
    /// (ASWebAuthenticationSessionError.canceledLogin) and on uninvited accounts
    /// (EkkoError.inviteOnly).
    func signInWithGoogle() async throws {
        var comps = URLComponents(url: Self.supabaseURL, resolvingAgainstBaseURL: false)!
        comps.path = "/auth/v1/authorize"
        comps.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: Self.callback),
        ]
        let url = comps.url!
        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { url, err in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: err ?? EkkoError.expiredOrInvalid) }
            }
            s.presentationContextProvider = presenter
            s.prefersEphemeralWebBrowserSession = false
            webAuthSession = s // keep alive for the duration of the flow
            s.start()
        }
        webAuthSession = nil
        try adoptSession(fromCallback: callbackURL)
    }

    /// Emails a one-time link (and an 8-digit code). New addresses create accounts.
    /// Links expire in 1 hour and are single-use; the code is the reliable path.
    func sendMagicLink(to email: String) async throws {
        _ = try await authPOST(
            path: "/auth/v1/otp",
            query: [URLQueryItem(name: "redirect_to", value: Self.callback)],
            body: ["email": email, "create_user": true]
        )
    }

    /// Signs in with the 8-digit code from the magic-link email. No deep link needed;
    /// smoothest path in the Simulator.
    func verifyCode(email: String, code: String) async throws {
        let data = try await authPOST(
            path: "/auth/v1/verify",
            body: ["type": "email", "email": email, "token": code]
        )
        try adoptSession(fromTokenResponse: data)
    }

    /// Native Sign in with Apple: the credential's identity token is exchanged directly for a
    /// session (grant_type=id_token) — no web round trip, no client secret. Supabase verifies the
    /// token's audience against this app's bundle id (the Apple provider's client id). `nonce` is
    /// the RAW value from `makeNonce()`; Apple's sheet was given its SHA-256, and Supabase hashes
    /// this one to check they are the same request.
    func signInWithApple(credential: ASAuthorizationAppleIDCredential, nonce: String) async throws {
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw EkkoError.expiredOrInvalid
        }
        let data = try await authPOST(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: ["provider": "apple", "id_token": idToken, "nonce": nonce]
        )
        try adoptSession(fromTokenResponse: data)
    }

    /// The Sign in with Apple nonce pair: hand `hashed` to the Apple request and `raw` to
    /// `signInWithApple` — the replay protection Apple and Supabase agree on.
    static func makeNonce() -> (raw: String, hashed: String) {
        let raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            .map { String(format: "%02x", $0) }.joined()
        let hashed = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return (raw, hashed)
    }

    /// Accepts ekko://auth-callback#access_token=... — wire to .onOpenURL for the
    /// magic-link deep link; signInWithGoogle() calls it internally.
    func adoptSession(fromCallback url: URL) throws {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              let items = URLComponents(string: "?" + fragment)?.queryItems else {
            throw EkkoError.expiredOrInvalid
        }
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let err = item("error_code") ?? item("error_description") ?? item("error") {
            let s = err.lowercased()
            throw s.contains("signup") ? EkkoError.inviteOnly : EkkoError.server(0, err)
        }
        guard let at = item("access_token"), let rt = item("refresh_token") else {
            throw EkkoError.expiredOrInvalid
        }
        let exp = item("expires_at").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval(item("expires_in").flatMap(Double.init) ?? 3600)
        setSession(EkkoSession(accessToken: at, refreshToken: rt, expiresAt: exp))
    }

    /// Call on foreground/app start. JWTs live 1 hour; refresh tokens rotate (10s
    /// reuse window), so the new pair is persisted atomically here.
    func refreshIfNeeded() async throws {
        guard let s = session else { throw EkkoError.notSignedIn }
        guard s.expiresAt.timeIntervalSinceNow < 300 else { return }
        try await refresh()
    }

    func signOut() async {
        if let s = session {
            var req = URLRequest(url: Self.supabaseURL.appendingPathComponent("auth/v1/logout"))
            req.httpMethod = "POST"
            req.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req) // best effort
        }
        setSession(nil)
    }

    // MARK: Profile / handle

    /// nil until a handle is claimed. Claim before search/connect: connections
    /// reference profiles server-side.
    func myProfile() async throws -> EkkoProfile? {
        guard let uid = userId else { throw EkkoError.notSignedIn }
        let data = try await rest("GET", "/profiles?user_id=eq.\(uid)&select=user_id,handle,display_name,public_key")
        return try Self.decoder.decode([EkkoProfile].self, from: data).first
    }

    /// Publish this device's PUBLIC key against your handle, so people can encrypt to you without
    /// you having to hand them a 1,600-character invite.
    ///
    /// Only a public key ever goes up. The private half is derived from the 24 words and never
    /// leaves the phone — that is not a policy, it is the shape of the thing: `engine.invite` has
    /// no private material in it to leak.
    func publishKey(_ invite: String) async throws {
        guard let uid = userId else { throw EkkoError.notSignedIn }
        _ = try await rest("PATCH", "/profiles?user_id=eq.\(uid)", body: ["public_key": invite])
    }

    /// Handle grammar: ^[a-z0-9_]{3,20}$, unique, first-claim-wins (.conflict if taken).
    func claimHandle(_ handle: String, displayName: String? = nil) async throws -> EkkoProfile {
        guard let uid = userId else { throw EkkoError.notSignedIn }
        var body: [String: Any] = ["user_id": uid, "handle": handle]
        if let displayName { body["display_name"] = displayName }
        let data = try await rest("POST", "/profiles", body: body)
        guard let p = try Self.decoder.decode([EkkoProfile].self, from: data).first else {
            throw EkkoError.notPermitted
        }
        return p
    }

    func changeHandle(to handle: String) async throws -> EkkoProfile {
        guard let uid = userId else { throw EkkoError.notSignedIn }
        let data = try await rest("PATCH", "/profiles?user_id=eq.\(uid)", body: ["handle": handle])
        guard let p = try Self.decoder.decode([EkkoProfile].self, from: data).first else {
            throw EkkoError.notPermitted
        }
        return p
    }

    // MARK: People

    /// Prefix search over all claimed handles (any signed-in user may search).
    func searchHandles(prefix raw: String) async throws -> [EkkoProfile] {
        let q = raw.lowercased().filter { "abcdefghijklmnopqrstuvwxyz0123456789_".contains($0) }
        guard !q.isEmpty else { return [] }
        let data = try await rest(
            "GET",
            "/profiles?handle=ilike.\(q)*&select=user_id,handle,display_name,public_key&order=handle&limit=10")
        return try Self.decoder.decode([EkkoProfile].self, from: data)
            .filter { $0.userId != userId }
    }

    /// All my edges, both directions and both statuses, peer profiles embedded — INCLUDING their
    /// public key, which is what lets an accepted connection become a real encrypted channel
    /// instead of a contact card.
    func connections() async throws -> [EkkoConnection] {
        let sel = "id,status,requester,addressee,"
            + "requester_profile:profiles!connections_requester_fkey(handle,display_name,public_key),"
            + "addressee_profile:profiles!connections_addressee_fkey(handle,display_name,public_key)"
        let data = try await rest("GET", "/connections?select=\(sel)&order=created_at.desc")
        return try Self.decoder.decode([EkkoConnection].self, from: data)
    }

    /// .conflict if an edge already exists in either direction.
    func sendRequest(to peerUserId: String) async throws {
        guard let uid = userId else { throw EkkoError.notSignedIn }
        _ = try await rest("POST", "/connections", body: ["requester": uid, "addressee": peerUserId])
    }

    /// Addressee-only, pending-only (RLS). Anything else -> .notPermitted.
    func accept(connectionId: String) async throws {
        let iso = ISO8601DateFormatter().string(from: Date())
        let data = try await rest(
            "PATCH", "/connections?id=eq.\(connectionId)",
            body: ["status": "accepted", "responded_at": iso])
        guard try !Self.decoder.decode([EkkoConnection].self, from: data).isEmpty else {
            throw EkkoError.notPermitted
        }
    }

    /// Decline, cancel and disconnect are all the same delete.
    func removeConnection(id: String) async throws {
        _ = try await rest("DELETE", "/connections?id=eq.\(id)")
    }

    // MARK: Session setup

    func sessionSetups() async throws -> [EkkoSessionSetup] {
        let fields = "connection_id,sender,recipient,sender_key,recipient_key,handshake"
        let data = try await rest("GET", "/session_setups?select=\(fields)")
        return try Self.decoder.decode([EkkoSessionSetup].self, from: data)
    }

    func publishSessionSetup(
        connectionId: String,
        recipient: String,
        senderKey: String,
        recipientKey: String,
        handshake: String
    ) async throws {
        _ = try await rest(
            "POST", "/session_setups",
            body: [
                "connection_id": connectionId,
                "recipient": recipient,
                "sender_key": senderKey,
                "recipient_key": recipientKey,
                "handshake": handshake,
                "updated_at": ISO8601DateFormatter().string(from: Date()),
            ],
            prefer: "return=representation,resolution=merge-duplicates")
    }

    // MARK: Socials

    /// Own socials, or a peer's (visible only once the connection is accepted;
    /// before that the server returns an empty list, not an error).
    func socials(of peerUserId: String? = nil) async throws -> [EkkoSocial] {
        guard let uid = peerUserId ?? userId else { throw EkkoError.notSignedIn }
        let data = try await rest(
            "GET", "/account_handles?user_id=eq.\(uid)&select=id,platform,handle&order=platform")
        return try Self.decoder.decode([EkkoSocial].self, from: data)
    }

    /// whatsapp = phone digits with country code; others are lowercased, "@" stripped.
    func addSocial(platform: String, handle raw: String) async throws -> EkkoSocial {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("@") { v.removeFirst() }
        v = platform == "whatsapp" ? v.filter(\.isNumber) : v.lowercased()
        guard !v.isEmpty, v.count <= 64 else { throw EkkoError.server(0, "invalid handle") }
        // user_id is filled server-side from auth.uid(); sending it spoofed would 403.
        let data = try await rest("POST", "/account_handles", body: ["platform": platform, "handle": v])
        guard let s = try Self.decoder.decode([EkkoSocial].self, from: data).first else {
            throw EkkoError.notPermitted
        }
        return s
    }

    func removeSocial(id: String) async throws {
        _ = try await rest("DELETE", "/account_handles?id=eq.\(id)")
    }

    // MARK: Encrypted key backup

    // What crosses this boundary is ciphertext and nothing else. The passphrase that opens it is
    // never sent, never derived server-side, and is not recoverable from anything here — which is
    // the entire reason the feature is allowed to exist. See src/core/backup.ts and docs/ACCOUNTS.md.

    private struct BackupRow: Decodable {
        let blob: Backup.Blob
        let updatedAt: Date?

        enum CodingKeys: String, CodingKey { case blob, updatedAt }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            blob = try c.decode(Backup.Blob.self, forKey: .blob)
            // Decoded by hand: Postgres sends "2026-07-14T01:52:25.104574+00:00" (SIX fractional
            // digits), and JSONDecoder's default date strategy expects a NUMBER, so leaving this to
            // the synthesised init makes every fetch fail — on a screen whose whole job is to tell
            // you your keys are safe. The timestamp is decoration; never let it sink the row.
            updatedAt = (try? c.decode(String.self, forKey: .updatedAt)).flatMap(Self.date)
        }

        private static func date(_ s: String) -> Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
    }

    /// nil when this account has never backed up. RLS makes this row invisible to everyone else,
    /// including accepted connections.
    func keyBackup() async throws -> (blob: Backup.Blob, updatedAt: Date?)? {
        let data = try await rest("GET", "/key_backups?select=blob,updated_at")
        guard let row = try Self.decoder.decode([BackupRow].self, from: data).first else { return nil }
        return (row.blob, row.updatedAt)
    }

    /// Upsert: one row per account, so backing up again replaces the previous blob rather than
    /// leaving older copies of the identity lying around in table history.
    func saveKeyBackup(_ blob: Backup.Blob) async throws {
        // user_id is filled from auth.uid() server-side; sending it would be a spoof attempt and RLS
        // would refuse the write.
        _ = try await rest(
            "POST", "/key_backups", body: ["blob": blob.asJSON],
            prefer: "return=representation,resolution=merge-duplicates")
    }

    func deleteKeyBackup() async throws {
        guard let uid = userId else { throw EkkoError.notSignedIn }
        // The filter is mandatory: PostgREST rejects an unfiltered DELETE outright ("DELETE
        // requires a WHERE clause"), so leaving it off is a 400, not a wiped table.
        _ = try await rest("DELETE", "/key_backups?user_id=eq.\(uid)")
    }

    // MARK: - Internals

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func setSession(_ s: EkkoSession?) {
        session = s
        if let s { Keychain.saveSession(s) } else { Keychain.deleteSession() }
    }

    private func refresh() async throws {
        guard let s = session else { throw EkkoError.notSignedIn }
        do {
            let data = try await authPOST(
                path: "/auth/v1/token",
                query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                body: ["refresh_token": s.refreshToken])
            try adoptSession(fromTokenResponse: data)
        } catch let e as EkkoError {
            // Server rejected the refresh token: the session is dead. Network errors
            // (URLError) pass through without clearing so offline does not sign out.
            setSession(nil)
            throw e
        }
    }

    private func adoptSession(fromTokenResponse data: Data) throws {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = o["access_token"] as? String,
              let rt = o["refresh_token"] as? String else {
            throw EkkoError.expiredOrInvalid
        }
        let exp = (o["expires_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval((o["expires_in"] as? Double) ?? 3600)
        setSession(EkkoSession(accessToken: at, refreshToken: rt, expiresAt: exp))
    }

    /// GoTrue call with the anon key only (no user session).
    private func authPOST(path: String, query: [URLQueryItem] = [], body: Any) async throws -> Data {
        var comps = URLComponents(url: Self.supabaseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        comps.queryItems = query.isEmpty ? nil : query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Self.mapError(code, data) }
        return data
    }

    /// PostgREST call as the signed-in user. One retry through refresh() on 401.
    /// Writes carry Prefer: return=representation, and RLS makes cross-owner writes
    /// come back EMPTY rather than erroring — callers treat empty as .notPermitted.
    @discardableResult
    private func rest(_ method: String, _ pathAndQuery: String, body: Any? = nil,
                      prefer: String? = nil, retried: Bool = false) async throws -> Data {
        guard let s = session else { throw EkkoError.notSignedIn }
        // pathAndQuery is built from sanitized values only (uuids, filtered handles).
        guard let url = URL(string: Self.supabaseURL.absoluteString + "/rest/v1" + pathAndQuery) else {
            throw EkkoError.server(0, "bad path")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" {
            req.setValue(prefer ?? "return=representation", forHTTPHeaderField: "Prefer")
        }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, !retried {
            try await refresh()
            return try await rest(method, pathAndQuery, body: body, prefer: prefer, retried: true)
        }
        guard (200..<300).contains(code) else { throw Self.mapError(code, data) }
        return data
    }

    private static func mapError(_ status: Int, _ data: Data) -> EkkoError {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let text = ["error_code", "code", "msg", "message", "error_description"]
            .compactMap { o[$0] as? String }.joined(separator: " ").lowercased()
        if status == 409 || text.contains("23505") { return .conflict }
        if text.contains("signup") || text.contains("otp_disabled") { return .inviteOnly }
        if text.contains("expired") || text.contains("otp") { return .expiredOrInvalid }
        if status == 401 || status == 403 { return .notPermitted }
        return .server(status, text.isEmpty ? "unexpected" : text)
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var p = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        p += String(repeating: "=", count: (4 - p.count % 4) % 4)
        guard let d = Data(base64Encoded: p) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

// MARK: - Plumbing

/// The system calls this on the main thread while the auth sheet presents.
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

/// Minimal Keychain wrapper for the one session blob.
private enum Keychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.useekko.account",
            kSecAttrAccount as String: "session",
        ]
    }

    static func saveSession(_ s: EkkoSession) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadSession() -> EkkoSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(EkkoSession.self, from: data)
    }

    static func deleteSession() {
        SecItemDelete(query as CFDictionary)
    }
}
