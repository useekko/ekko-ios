import EkkoCore
import SwiftUI

struct ContactsView: View {
    @Environment(EkkoEngine.self) private var engine

    @State private var showAdd = false
    @State private var showInvite = false

    var body: some View {
        NavigationStack {
            Group {
                if engine.contacts.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.bg)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a contact")
                }
            }
            .navigationDestination(for: String.self) { id in
                ContactDetailView(contactID: id)
            }
            .sheet(isPresented: $showAdd) { AddContactSheet() }
            .sheet(isPresented: $showInvite) { InviteSheet() }
        }
    }

    private var list: some View {
        List(engine.contacts) { contact in
            NavigationLink(value: contact.id) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(contact.label)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Ink.ink)
                        if contact.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Ink.accentDeep)
                                .accessibilityLabel("Verified")
                        }
                    }
                    Text(contact.fingerprintHex)
                        .font(.machine(11))
                        .foregroundStyle(Ink.faint)
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Ink.surface)
            .listRowSeparatorTint(Ink.line)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Text("No one to talk to yet.")
                .font(.display(28))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("An invite is your public key. It is safe to send over any channel, including one you do not trust.")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button("Share your invite") { showInvite = true }
                    .buttonStyle(AccentButton())

                Button("Add someone's invite") { showAdd = true }
                    .buttonStyle(QuietButton(wide: true))
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 460)
    }
}

// MARK: - Sheets

/// Your invite, as a sheet. Reached from the empty chat list and from a person's profile — where
/// "share your invite" is the one action that turns an address into an encrypted channel.
struct InviteSheet: View {
    @Environment(EkkoEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Let them scan this, or send them the text. They add it in Ekko and send the one-time setup response back; none of that appears in your conversation.")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if let invite = engine.invite {
                        InviteCard(invite: invite)
                    } else {
                        Text("No identity on this phone yet.")
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.muted)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.bg)
            .navigationTitle("Your invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct AddContactSheet: View {
    @Environment(EkkoEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var invite = ""
    @State private var name = ""
    @State private var failure: String?
    @State private var pairingSetup: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let pairingSetup {
                        Text("Send this setup back once")
                            .font(.display(28))
                            .foregroundStyle(Ink.ink)

                        Text("This finishes the post-quantum channel before either of you writes in a messenger. They paste it into Add someone; it never appears in your conversation.")
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        CopyButton(text: pairingSetup, label: "Copy setup response")

                        Button("Done") { dismiss() }
                            .buttonStyle(AccentButton())
                    } else {
                        Text("Paste the invite or setup response they sent you. It starts with EKK1I or EKK1H.")
                            .font(.system(size: 15))
                            .foregroundStyle(Ink.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Their invite").kickerStyle()

                            TextEditor(text: $invite)
                                .font(.machine(12))
                                .foregroundStyle(Ink.ink)
                                .scrollContentBackground(.hidden)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .frame(minHeight: 130)
                                .padding(10)
                                .background(Ink.surface, in: .rect(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line, lineWidth: 1))
                                .accessibilityLabel("Their invite")

                            Button {
                                invite = UIPasteboard.general.string ?? invite
                                failure = nil
                            } label: {
                                Label("Paste", systemImage: "doc.on.clipboard")
                            }
                            .buttonStyle(QuietButton())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Name (optional)").kickerStyle()

                            TextField("What you want to call them", text: $name)
                                .font(.system(size: 16))
                                .foregroundStyle(Ink.ink)
                                .padding(12)
                                .background(Ink.surface, in: .rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line, lineWidth: 1))
                        }

                        if let failure {
                            Label(failure, systemImage: "exclamationmark.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button("Add contact", action: add)
                            .buttonStyle(AccentButton())
                            .disabled(invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.bg)
            .navigationTitle(pairingSetup == nil ? "Add someone" : "Finish pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if pairingSetup == nil { Button("Cancel") { dismiss() } }
                }
            }
        }
    }

    private func add() {
        do {
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let contact = try engine.addContact(
                invite: invite, label: label.isEmpty ? nil : label)
            if let setup = try engine.prepareSetup(to: contact) {
                pairingSetup = setup
            } else {
                dismiss()
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}
