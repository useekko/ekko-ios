import EkkoCore
import SwiftUI

struct RootView: View {
    @Environment(EkkoEngine.self) private var engine
    @Environment(AppEngine.self) private var app
    @EnvironmentObject private var account: EkkoAccount
    @Environment(\.scenePhase) private var scenePhase
    /// `createIdentity()` makes `hasIdentity` true the moment it returns, so identity alone cannot
    /// gate the app: it would swap this view to HomeView while the 24 words are still unread.
    /// Onboarding sets this when the user is actually set up.
    @AppStorage(onboardedKey) private var onboarded = false

    var body: some View {
        @Bindable var app = app

        Group {
            if engine.hasIdentity && onboarded {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .background(Ink.bg)
        // The keyboard extension writes to the same vault file. Re-read whenever we come back,
        // or the app would show a stale contact list after a conversation.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            engine.reload()
            Task {
                // Access tokens live an hour. Refreshing on the way in means the first tap of a
                // signed-in screen is not the one that discovers the session went stale overnight.
                try? await account.refreshIfNeeded()
                // Publish our public key, and pick up the keys of anyone we are now connected to,
                // so the KEYBOARD has someone to seal to without the user doing anything. It runs
                // here rather than on a screen because the keyboard is not a screen — a person who
                // accepts a connection on the web and then opens their messenger never visits the
                // app at all.
                await AccountSync.run(account: account, engine: engine)
                engine.reload()
            }
        }
        // The magic link can land while any tab is open, so its failure is reported here rather
        // than inside the account screen the user may never have reached.
        .errorAlert($app.authError)
    }
}
