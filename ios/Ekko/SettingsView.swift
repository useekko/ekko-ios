import EkkoCore
import SwiftUI

struct SettingsView: View {
    @Environment(EkkoEngine.self) private var engine
    @Environment(AppEngine.self) private var app
    @AppStorage(onboardedKey) private var onboarded = false

    @State private var confirmDelete = false
    @State private var error: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if let storeError = app.storeError {
                        warning(storeError)
                    }
                    keyboard
                    safari
                    about
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.bg)
            .navigationTitle("Settings")
            .errorAlert($error)
        }
    }

    private func warning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Ink.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.red.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard").kickerStyle()

            Text("If the Ekko keyboard does not appear when you tap the globe key, it is not turned on yet.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            KeyboardSetupSteps()
                .card(padding: 20)

            OpenSettingsButton()

            NavigationLink {
                KeyboardTestView()
            } label: {
                HStack {
                    Text("Try the keyboard")
                        .font(.system(size: 16))
                        .foregroundStyle(Ink.ink)
                    Spacer(minLength: 12)
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

    private var safari: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open in Safari").kickerStyle()

            Text("Tap a messenger to open it in Safari, where Ekko reads and writes sealed messages right in the page. This is the one place on iPhone where Ekko can decrypt in place, so open them here rather than from the home screen.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(SafariMessenger.all.enumerated()), id: \.element.name) { i, m in
                    if i > 0 { Divider().overlay(Ink.line) }
                    Button { open(m) } label: {
                        HStack(spacing: 12) {
                            PlatformMark(platform: m.platform, size: 30)
                            Text(m.name)
                                .font(.system(size: 16))
                                .foregroundStyle(Ink.ink)
                            Spacer(minLength: 12)
                            Image(systemName: "safari")
                                .font(.system(size: 15))
                                .foregroundStyle(Ink.faint)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Ink.faint)
                        }
                        .contentShape(.rect)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(m.name) in Safari")
                }
            }
            .card(padding: 16)

            Text("Not seeing Ekko in the page? Turn the extension on in Settings, then Apps, then Safari, then Extensions. It opens in your default browser, so keep Safari as the default.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func open(_ m: SafariMessenger) {
        // A plain https URL opens in the DEFAULT browser. For anyone who set up the Safari
        // extension that is Safari, which is the only browser the extension lives in anyway — there
        // is no public API to force a specific browser, and forcing one would be wrong if they use
        // Safari as default (they do, or the extension would be pointless). Home-screen "web app"
        // shortcuts run in a standalone WebKit with NO extensions, which is why we send people
        // through Safari instead. See docs/IOS.md.
        UIApplication.shared.open(m.url)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About").kickerStyle()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Version")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.inkSoft)
                    Spacer(minLength: 12)
                    Text(version)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.muted)
                }
                Divider().overlay(Ink.line)
                HStack {
                    Text("Web")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.inkSoft)
                    Spacer(minLength: 12)
                    if let url = URL(string: "https://useekko.app") {
                        Link("useekko.app", destination: url)
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.accentDeep)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 16)

            Button("Delete identity", role: .destructive) { confirmDelete = true }
                .buttonStyle(DangerButton())
                .confirmationDialog(
                    "Delete this identity?",
                    isPresented: $confirmDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete identity", role: .destructive, action: destroy)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This erases your keys, your contacts and your sessions from this phone. Your 24 word recovery phrase is the only way back. Without it, this identity is gone and no one can reach you at it again.")
                }
        }
    }

    private func destroy() {
        do {
            try engine.destroyIdentity()
            onboarded = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A messenger the Safari extension covers. The URLs must land on a page the content script
/// matches (see the manifest's content_scripts / scripts/ios-safari-sync.mjs), or the launcher
/// opens a page Ekko never touches. Deep-linking straight to the inbox where one exists saves a tap.
struct SafariMessenger {
    let platform: Platform
    let name: String
    let url: URL

    static let all: [SafariMessenger] = [
        SafariMessenger(
            platform: Platform.named("instagram")!, name: "Instagram",
            url: URL(string: "https://www.instagram.com/direct/inbox/")!),
        SafariMessenger(
            platform: Platform.named("whatsapp")!, name: "WhatsApp Web",
            url: URL(string: "https://web.whatsapp.com/")!),
        SafariMessenger(
            platform: Platform.named("telegram")!, name: "Telegram Web",
            url: URL(string: "https://web.telegram.org/")!),
        SafariMessenger(
            platform: Platform.named("messenger")!, name: "Messenger",
            url: URL(string: "https://www.messenger.com/")!),
    ]
}
