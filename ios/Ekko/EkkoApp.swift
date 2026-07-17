import EkkoCore
import SwiftUI

@main
struct EkkoApp: App {
    @State private var engine = AppEngine()
    /// The account is a SEPARATE identity from the keys. It holds the @handle and the people; it
    /// never sees a private key. See docs/ACCOUNTS.md and GOAL.md.
    @StateObject private var account = EkkoAccount()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine.engine)
                .environment(engine)
                .environmentObject(account)
                .tint(Ink.accent)
                .onOpenURL { url in
                    // ekko://auth-callback#access_token=… — the magic link coming back from Safari.
                    guard url.scheme == "ekko" else { return }
                    do { try account.adoptSession(fromCallback: url) }
                    catch { engine.authError = error.localizedDescription }
                }
        }
    }
}

/// App-level state that is not the crypto broker: the store handle and the errors that arrive from
/// outside a view (the App Group check at launch, the magic link at any moment).
@Observable
final class AppEngine {
    let engine: EkkoEngine
    var storeError: String?
    var authError: String?

    init() {
        // A missing App Group is a build/provisioning fault, not a user state — surface it rather
        // than crashing, so the simulator tells us instead of dying silently.
        if let e = try? EkkoEngine() {
            engine = e
        } else {
            engine = EkkoEngine(store: EkkoStore(directory: FileManager.default.temporaryDirectory))
            storeError = "Ekko's shared container is unavailable, so nothing will persist. Check the App Group entitlement."
        }
    }
}
