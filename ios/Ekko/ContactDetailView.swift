import EkkoCore
import SwiftUI

struct ContactDetailView: View {
    @Environment(EkkoEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    let contactID: String

    @State private var name = ""
    @State private var safety: String?
    @State private var error: String?
    @State private var confirmRemove = false

    private var contact: Contact? { engine.contact(id: contactID) }

    var body: some View {
        ScrollView {
            if let contact {
                VStack(alignment: .leading, spacing: 28) {
                    nameField
                    safetyNumber(contact)
                    verification(contact)
                    removal(contact)
                }
                .padding(20)
            } else {
                Text("This contact is no longer in your list.")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.muted)
                    .padding(40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.bg)
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
        .task {
            guard let contact else { return }
            name = contact.label
            do {
                safety = try engine.safetyNumber(for: contact)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear(perform: commitName)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name").kickerStyle()

            TextField("Name", text: $name)
                .font(.display(30))
                .foregroundStyle(Ink.ink)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit(commitName)
                .accessibilityLabel("Contact name")

            Text("Only you see this name.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
        }
    }

    private func safetyNumber(_ contact: Contact) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Safety number").kickerStyle()

            if let safety {
                let groups = safety.split(separator: " ").map(String.init)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        Text(group)
                            .font(.machine(15))
                            .foregroundStyle(Ink.ink)
                    }
                }
                .frame(maxWidth: .infinity)
                .card(padding: 18)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Safety number \(safety)")

                CopyButton(text: safety, label: "Copy safety number")
            } else {
                Text("Safety number unavailable.")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.muted)
            }

            Text("Compare these 60 digits with \(contact.label) over a different channel, in person or on a voice call. If they match, no one is in the middle.")
                .font(.system(size: 14))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func verification(_ contact: Contact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { contact.verified },
                set: { verified in
                    do {
                        try engine.setVerified(contact, verified)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(contact.verified ? Ink.accentDeep : Ink.faint)
                    Text("Mark as verified")
                        .font(.system(size: 16))
                        .foregroundStyle(Ink.ink)
                }
            }
            .card(padding: 16)

            Text("Turn this on once the digits matched. It is a note to yourself, and it does not change the encryption.")
                .font(.system(size: 13))
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func removal(_ contact: Contact) -> some View {
        Button("Remove contact", role: .destructive) { confirmRemove = true }
            .buttonStyle(DangerButton())
            .confirmationDialog(
                "Remove \(contact.label)?",
                isPresented: $confirmRemove,
                titleVisibility: .visible
            ) {
                Button("Remove contact", role: .destructive) {
                    do {
                        try engine.remove(contact)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This also drops the secure session with them. Messages they already sent you will stop opening, and the next one starts a new session.")
            }
    }

    private func commitName() {
        guard let contact else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != contact.label else { return }
        do {
            try engine.rename(contact, to: trimmed)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
