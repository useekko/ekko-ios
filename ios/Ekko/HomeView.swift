import EkkoCore
import SwiftUI

/// Chats and People are both lists of humans, and they are deliberately not the same list.
///
/// A CHAT is a key: someone whose invite you hold, whom you can seal a message to. A PERSON is an
/// address: someone whose @handle you found, whose apps you can see. Ekko keeps the two apart on
/// purpose (docs/ACCOUNTS.md — the account scaffold never touches the key directory), so the tabs
/// keep them apart too, and each screen says which one it is.
struct HomeView: View {
    var body: some View {
        TabView {
            Tab("Chats", systemImage: "lock.fill") {
                ContactsView()
            }
            Tab("People", systemImage: "at") {
                PeopleView()
            }
            Tab("Identity", systemImage: "person.badge.key") {
                IdentityView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}
