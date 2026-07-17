import EkkoCore
import SwiftUI
import UIKit

// Ekko has three deliberate surfaces:
//
//   compose -> recipient, Paste, Seal, then a familiar QWERTY plane
//   emoji   -> the native-height Emoji browser without app chrome competing for space
//   read    -> a private full-height reader; plaintext never enters the host composer
//
// Compose/read share one fixed envelope. Emoji uses the measured system Emoji height because
// squeezing five rows, search, categories, and the footer into the QWERTY height is not parity.

struct KeyboardView: View {
    @Bindable var model: KeyboardModel
    var showsGlobe: Bool
    var onHeightChange: (CGFloat) -> Void

    var body: some View {
        ZStack {
            if model.readerVisible {
                DecryptionReader(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                ComposeKeyboard(model: model, showsGlobe: showsGlobe)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.keyBacking)
        .animation(.easeOut(duration: 0.2), value: model.readerVisible)
        .onAppear { onHeightChange(desiredHeight) }
        .onChange(of: desiredHeight) { _, height in onHeightChange(height) }
        // Do not put an accessibility identifier here. SwiftUI containers pass identifiers down
        // to every descendant, which would make all letter keys expose the same identifier.
    }

    private var desiredHeight: CGFloat {
        if model.readerVisible { return 270 }
        return model.plane == .emoji ? NativeKeyboardMetrics.emojiPlaneHeight : 270
    }
}

// MARK: - Compose

private struct ComposeKeyboard: View {
    @Bindable var model: KeyboardModel
    var showsGlobe: Bool

    var body: some View {
        Group {
            if model.plane == .emoji {
                KeyPlaneView(model: model, showsGlobe: showsGlobe)
            } else {
                VStack(spacing: 0) {
                    CompactBar(model: model)
                    Rectangle().fill(Ink.keyboardLine).frame(height: 1)
                    KeyPlaneView(model: model, showsGlobe: showsGlobe)
                        .padding(.vertical, 1)
                }
            }
        }
        .background(Ink.keyBacking)
    }
}

/// One bar, one job at a time. Idle guidance used to consume another permanent 52pt row; the few
/// states that actually require attention now temporarily replace this bar instead.
private struct CompactBar: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        Group {
            if let sealed = model.sealing {
                SealDissolve(sealed: sealed) { model.sealing = nil }
            } else if model.showContacts {
                ContactPicker(model: model)
            } else if let queue = model.queue {
                QueueRow(model: model, queue: queue)
            } else if let status = model.status {
                StatusBar(model: model, status: status)
            } else {
                ActionBar(model: model)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
        .background(Ink.keyboardChrome)
        .clipped()
        .animation(.easeOut(duration: 0.14), value: model.showContacts)
    }
}

private struct ActionBar: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        HStack(spacing: 8) {
            RecipientControl(model: model)

            Spacer(minLength: 0)

            PasteControl(enabled: model.canDecrypt) { model.decrypt($0) }
                .frame(width: 88, height: 34)
                .accessibilityIdentifier("ekko-decrypt")

            if model.locked, model.contact != nil, model.queue == nil {
                Button(action: model.seal) {
                    Label("Seal", systemImage: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: 0xff_766c), Ink.coral],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: .rect(cornerRadius: 10)
                        )
                        .shadow(color: Ink.coral.opacity(0.28), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ekko-seal")
                .accessibilityHint("Replace the message in the app with encrypted text")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusBar: View {
    @Bindable var model: KeyboardModel
    let status: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isError ? Ink.danger : Ink.accentDeep)

            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.keyboardInk)
                .lineLimit(2)

            Spacer(minLength: 2)

            PasteControl(enabled: model.canDecrypt) { model.decrypt($0) }
                .frame(width: 82, height: 34)
                .accessibilityIdentifier("ekko-decrypt")

            Button { model.status = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.keyboardInk)
                    .frame(width: 32, height: 32)
                    .background(Ink.keyModifier, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss status")
        }
        .padding(.horizontal, 10)
    }

    private var isError: Bool {
        let value = status.lowercased()
        return value.contains("could not") || value.contains("can't") || value.contains("failed")
    }
}

private struct RecipientControl: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        Button {
            guard !model.contacts.isEmpty else { return }
            model.showContacts.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(
                            model.locked
                                ? Ink.coral.opacity(0.18) : Ink.keyboardInk.opacity(0.08)
                        )
                    Image(systemName: model.locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(model.locked ? Ink.accentDeep : Ink.keyboardMuted)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 0) {
                    Text(eyebrow)
                        .font(.system(size: 9, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(Ink.keyboardMuted)
                    Text(primary)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.keyboardInk)
                        .lineLimit(1)
                }

                if !model.contacts.isEmpty {
                    Image(systemName: model.showContacts ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.keyboardMuted)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, model.contacts.isEmpty ? 9 : 7)
            .frame(height: 34)
            .background(Ink.key.opacity(0.74), in: .rect(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        model.locked ? Ink.coral.opacity(0.35) : Ink.keyboardLine,
                        lineWidth: 1
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityIdentifier("ekko-lock")
        .accessibilityHint(model.contacts.isEmpty ? "" : "Choose who this message is sealed to")
    }

    private var eyebrow: String {
        if model.locked { return "Protected to" }
        if model.setupNeeded != nil { return "Ekko" }
        return "Sending"
    }

    private var primary: String {
        if model.locked, let contact = model.contact { return contact.label }
        if model.setupNeeded != nil {
            return model.canDecrypt ? "No contacts yet" : "Setup required"
        }
        return "Plain text"
    }

    private var accessibilityTitle: String {
        guard model.locked, let contact = model.contact else { return "Not encrypting" }
        return "Sealing to \(contact.label)"
    }
}

// MARK: - Compact states

private struct QueueRow: View {
    @Bindable var model: KeyboardModel
    let queue: KeyboardModel.SendQueue

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Ink.coral.opacity(0.12))
                Image(systemName: queue.total > 1 ? "square.stack.3d.up.fill" : "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Ink.accentDeep)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(queue.total > 1 ? "Encrypted part \(queue.index + 1) of \(queue.total)" : "Message sealed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.keyboardInk)
                Text(model.status ?? "Press Send in the app.")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.keyboardMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            PasteControl(enabled: model.canDecrypt) { model.decrypt($0) }
                .frame(width: 82, height: 34)
                .accessibilityIdentifier("ekko-decrypt")

            Button { model.cancelQueue() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.keyboardInk)
                    .frame(width: 32, height: 32)
                    .background(Ink.keyModifier, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel sealed message")
        }
        .padding(.horizontal, 10)
    }
}

private struct ContactPicker: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Button {
                        model.locked = false
                        model.showContacts = false
                    } label: {
                        chip(label: "Plain text", icon: "lock.open", selected: !model.locked)
                    }
                    .buttonStyle(.plain)

                    ForEach(model.contacts) { contact in
                        Button { model.pick(contact) } label: {
                            chip(
                                label: contact.label,
                                icon: contact.verified ? "checkmark.seal.fill" : "lock.fill",
                                selected: model.locked && model.contact?.id == contact.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(height: 48)
            }

            Button { model.showContacts = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.keyboardInk)
                    .frame(width: 32, height: 32)
                    .background(Ink.keyModifier, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close contacts")
            .padding(.trailing, 8)
        }
    }

    private func chip(label: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(selected ? Color.white : Ink.keyboardInk)
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(
            selected ? AnyShapeStyle(Ink.coral) : AnyShapeStyle(Ink.key),
            in: .capsule
        )
        .overlay {
            if !selected {
                Capsule().strokeBorder(Ink.keyboardLine, lineWidth: 1)
            }
        }
    }
}

// MARK: - Seal feedback

private struct SealDissolve: View {
    let sealed: KeyboardModel.Sealed
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cipher: [Character] = []
    @State private var cut = 0

    private static let glyphs = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    private var plain: [Character] { Array(sealed.text) }
    private var done: Bool { cut >= plain.count }
    private var shown: String { String(cipher.prefix(cut) + plain.dropFirst(cut)) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Ink.coral.opacity(0.12))
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Ink.accentDeep)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Sealed to \(sealed.to)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.keyboardInk)
                Text(shown)
                    .font(.machine(11))
                    .foregroundStyle(done ? Ink.accentDeep : Ink.keyboardMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sealed to \(sealed.to)")
        .task { await run() }
    }

    private func run() async {
        cipher = plain.map { _ in Self.glyphs.randomElement() ?? "x" }
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if reduceMotion {
            cut = plain.count
        } else {
            let step = max(1, plain.count / 24)
            while cut < plain.count {
                do {
                    try await Task.sleep(for: .milliseconds(18))
                } catch {
                    return
                }
                cut = min(plain.count, cut + step)
            }
        }

        do {
            try await Task.sleep(for: .milliseconds(260))
        } catch {
            return
        }
        onDone()
    }
}

// MARK: - Private reader

private struct DecryptionReader: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            ReaderHeader(model: model)
            Rectangle().fill(Ink.keyboardLine).frame(height: 1)
            ReaderContent(result: model.decrypted)
                .id(model.decryptRevision)
                .transition(.opacity)
            Rectangle().fill(Ink.keyboardLine).frame(height: 1)
            ReaderFooter(model: model)
        }
        .background(Ink.readerBacking)
        .onAppear { notify() }
        .onChange(of: model.decryptRevision) { _, _ in notify() }
        .animation(.easeOut(duration: 0.16), value: model.decryptRevision)
    }

    private func notify() {
        let feedback = UINotificationFeedbackGenerator()
        switch model.decrypted {
        case .failed, .unknownSession:
            feedback.notificationOccurred(.error)
        case .needMoreChunks:
            feedback.notificationOccurred(.warning)
        case .message, .secureChannel, .invited:
            feedback.notificationOccurred(.success)
        case .none:
            break
        }
    }
}

private struct ReaderHeader: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.13))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.keyboardInk)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Ink.keyboardMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button { model.dismissDecrypted() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Ink.keyboardInk)
                    .frame(width: 32, height: 32)
                    .background(Ink.keyModifier, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close decrypted message")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(Ink.keyboardChrome)
    }

    private var title: String {
        switch model.decrypted {
        case .message(_, let from, let mine): mine ? "Your sealed message" : "From \(from)"
        case .secureChannel(let with, _): "Secure channel with \(with)"
        case .invited(let label): "Invite from \(label)"
        case .needMoreChunks(let have, let total): "Message part \(have) of \(total)"
        case .unknownSession: "This message cannot open here"
        case .failed: "Could not open that"
        case .none: "Ekko"
        }
    }

    private var subtitle: String {
        switch model.decrypted {
        case .message: "Decrypted only on this iPhone"
        case .secureChannel: "Ready for protected messages"
        case .invited: "Public key added on this iPhone"
        case .needMoreChunks: "Copy and Paste the next bubble"
        case .unknownSession, .failed: "Your copied text was not changed"
        case .none: ""
        }
    }

    private var icon: String {
        switch model.decrypted {
        case .message: "lock.open.fill"
        case .secureChannel: "checkmark.shield.fill"
        case .invited: "person.crop.circle.badge.plus"
        case .needMoreChunks: "square.stack.3d.up.fill"
        case .unknownSession, .failed: "exclamationmark.triangle.fill"
        case .none: "lock.fill"
        }
    }

    private var tint: Color {
        switch model.decrypted {
        case .unknownSession, .failed: Ink.danger
        case .needMoreChunks: Ink.warning
        default: Ink.accentDeep
        }
    }
}

private struct ReaderContent: View {
    let result: KeyboardModel.Decrypted

    var body: some View {
        Group {
            switch result {
            case .message(let text, _, _):
                ScrollView(.vertical) {
                    Text(text)
                        .font(.display(18, .regular))
                        .foregroundStyle(Ink.keyboardInk)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
                .scrollBounceBehavior(.basedOnSize)

            case .secureChannel(let with, let added):
                ReaderNotice(
                    icon: "checkmark.shield.fill",
                    title: added ? "\(with) is now a contact" : "Channel confirmed",
                    message: "You can close this reader and reply with a sealed message.",
                    tint: Ink.accentDeep
                )

            case .invited(let label):
                ReaderNotice(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "\(label) was added",
                    message: "Open Ekko to finish the one-time secure setup before you message them.",
                    tint: Ink.accentDeep
                )

            case .needMoreChunks(let have, let total):
                ReaderNotice(
                    icon: "square.stack.3d.up.fill",
                    title: "Keep going",
                    message: "This encrypted message has \(total) parts. Copy the next bubble, then tap Paste below.",
                    tint: Ink.warning,
                    progress: Double(have) / Double(max(total, 1))
                )

            case .unknownSession:
                ReaderNotice(
                    icon: "key.slash.fill",
                    title: "The secure session is missing",
                    message: "This was sealed for another or expired session. Reconnect with the sender in Ekko, then ask them to resend it.",
                    tint: Ink.danger
                )

            case .failed(let reason):
                ReaderNotice(
                    icon: "doc.text.magnifyingglass",
                    title: "Copy the complete bubble",
                    message: reason,
                    tint: Ink.danger
                )

            case .none:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.readerBacking)
    }
}

private struct ReaderNotice: View {
    let icon: String
    let title: String
    let message: String
    let tint: Color
    var progress: Double?

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.1), in: .circle)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.keyboardInk)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.keyboardMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress {
                ProgressView(value: progress)
                    .tint(tint)
                    .frame(maxWidth: 180)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReaderFooter: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        HStack(spacing: 9) {
            PasteControl(enabled: model.canDecrypt) { model.decrypt($0) }
                .frame(width: 94, height: 36)
                .accessibilityIdentifier("ekko-decrypt-next")

            Text(pastePrompt)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Ink.keyboardMuted)
                .lineLimit(2)

            Spacer(minLength: 4)

            Button { model.dismissDecrypted() } label: {
                Label(primaryTitle, systemImage: primaryIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primary ? Color.white : Ink.keyboardInk)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(
                        primary ? AnyShapeStyle(Ink.coral) : AnyShapeStyle(Ink.keyModifier),
                        in: .rect(cornerRadius: 10)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(Ink.keyboardChrome)
    }

    private var pastePrompt: String {
        if case .needMoreChunks = model.decrypted { return "Next part" }
        return "Open another"
    }

    private var primary: Bool {
        switch model.decrypted {
        case .message(_, _, let mine): !mine
        case .secureChannel: true
        default: false
        }
    }

    private var primaryTitle: String { primary ? "Reply" : "Done" }
    private var primaryIcon: String { primary ? "lock.fill" : "checkmark" }
}
