import EkkoCore
import SwiftUI

/// The people side of Ekko: find someone by their @handle, ask to connect, and see where they can be
/// reached. It is the account's social graph, and it is NOT the key directory — connecting here
/// never moves a key. ProfileView says that out loud; this screen just gets you there.
///
/// It lives as its own tab because finding a person is a primary act, and it used to be three
/// levels deep (Identity > Account > a section halfway down a 700-line scroll).
struct PeopleView: View {
    @Environment(EkkoEngine.self) private var engine
    @EnvironmentObject private var account: EkkoAccount

    @State private var profile: EkkoProfile?
    @State private var connections: [EkkoConnection] = []
    @State private var query = ""
    @State private var results: [EkkoProfile] = []
    @State private var searched = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if !account.isSignedIn {
                        signedOut
                    } else if profile == nil && loaded {
                        needsHandle
                    } else {
                        if searched { searchResults }
                        requests
                        connected
                    }
                }
                .padding(20)
                .padding(.bottom, 24)  // the floating tab bar overlays the tail of the scroll
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.bg)
            .navigationTitle("People")
            // The system search field, not a hand-rolled one. It used to be a text box under a
            // full-width gradient Search button, which made the loudest object on the screen a
            // submit control — and DESIGN.md spends accent on the one thing that matters, which
            // here is connecting to a person, not running a query.
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Find someone by handle")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search, runSearch)
            .onChange(of: query) { _, now in
                if now.trimmingCharacters(in: .whitespaces).isEmpty {
                    results = []
                    searched = false
                }
            }
            .navigationDestination(for: EkkoProfile.self) { person in
                ProfileView(profile: person) { Task { await reload() } }
            }
            // A profile can walk you straight to the safety number of the contact it just gave you.
            .navigationDestination(for: String.self) { contactID in
                ContactDetailView(contactID: contactID)
            }
            .errorAlert($error)
            .task(id: account.userId) { await reload() }
            .refreshable { await reload() }
        }
    }

    // MARK: - Find

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Results").kickerStyle()

            if results.isEmpty {
                Text("No one has claimed that handle.")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 16)
            } else {
                ForEach(results) { person in
                    NavigationLink(value: person) {
                        PersonRow(
                            handle: person.handle,
                            subtitle: person.displayName,
                            trailing: standing(with: person.userId))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// What a search hit already is to you, so you never send a second request to someone you are
    /// already connected to.
    private func standing(with userId: String) -> String? {
        guard let me = account.userId,
              let c = connections.first(where: { $0.peer(of: me).userId == userId })
        else { return nil }
        if c.status == "accepted" { return "Connected" }
        return c.requester == me ? "Asked" : "Wants to connect"
    }

    // MARK: - Requests to you

    @ViewBuilder private var requests: some View {
        let incoming = edges { $0.status == "pending" && $0.addressee == account.userId }
        if !incoming.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Wants to connect").kickerStyle()
                rows(incoming)
            }
        }
    }

    // MARK: - Your people

    @ViewBuilder private var connected: some View {
        let accepted = edges { $0.status == "accepted" }
        let outgoing = edges { $0.status == "pending" && $0.requester == account.userId }

        VStack(alignment: .leading, spacing: 14) {
            Text("Connected").kickerStyle()

            if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if accepted.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No one yet.")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.inkSoft)
                    Text("Search for a handle. Once you are connected you can see which apps they are on, and open a chat with them in one tap.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
            } else {
                rows(accepted)
            }
        }

        if !outgoing.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Waiting on them").kickerStyle()
                rows(outgoing)
            }
        }
    }

    // MARK: - Signed out / no handle

    private var signedOut: some View {
        // No kicker here: the navigation title already says People, and a section label repeating it
        // is the screen talking to itself.
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Finding people needs an account.")
                    .font(.display(24))
                    .foregroundStyle(Ink.ink)

                Text("An account is a handle other people can find you at, and a list of the apps you are on. It never holds a key: those live in your 24 words, on this phone. Ekko works perfectly without one.")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 16)

            SignInCard()
        }
    }

    private var needsHandle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claim your handle").kickerStyle()

            Text("People find each other by handle, so you need one before you can connect with anyone.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)

            HandleClaimCard { claimed in
                profile = claimed
                try? engine.setUsername(claimed.handle)
            }
        }
    }

    // MARK: - Plumbing

    private func edges(_ match: (EkkoConnection) -> Bool) -> [EkkoConnection] {
        connections.filter(match)
    }

    @ViewBuilder private func rows(_ edges: [EkkoConnection]) -> some View {
        ForEach(edges) { c in
            let peer = c.peer(of: account.userId ?? "")
            let person = EkkoProfile(
                userId: peer.userId,
                handle: peer.profile?.handle ?? peer.userId,
                displayName: peer.profile?.displayName)

            NavigationLink(value: person) {
                PersonRow(handle: person.handle, subtitle: person.displayName)
            }
            .buttonStyle(.plain)
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
        guard !q.isEmpty else { return }
        Task { @MainActor in
            do {
                results = try await account.searchHandles(prefix: q)
                searched = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func reload() async {
        guard account.isSignedIn else {
            profile = nil
            connections = []
            loaded = true
            return
        }
        do {
            profile = try await account.myProfile()
            connections = try await account.connections()
        } catch {
            self.error = error.localizedDescription
        }
        // Publish our key and adopt anyone new. Quiet and idempotent: if it fails we simply have not
        // synced yet, which is not a thing to interrupt someone with.
        await AccountSync.run(account: account, engine: engine)
        engine.reload()
        loaded = true
    }
}
