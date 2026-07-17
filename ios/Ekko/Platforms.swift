import SwiftUI
import UIKit

// Where a person can be reached. One registry, used by the account screen (your addresses) and the
// profile screen (theirs) — a platform is a place a human lives, not a feature flag.
//
// Keep in step with CONNECT_APPS in src/popup/popup.ts and the platform list the account backend
// accepts (docs/ACCOUNTS.md). Brand colour is deliberate: DESIGN.md reserves exactly one loud,
// consumer-coloured element, and this is it. Everything around it stays monochrome.

struct Platform: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
    /// What to type when you list yourself here.
    let hint: String

    /// Official single-colour vector mark, ported from the popup's BRANDS registry. The asset is a
    /// template so this registry remains the one source of truth for its light/dark-safe colour.
    var iconAsset: String { "social-\(id)" }

    /// WhatsApp addresses a phone number, not a handle. It is the only one, and it changes the
    /// keyboard, the formatting and the link.
    var isPhone: Bool { id == "whatsapp" }

    static let all: [Platform] = [
        Platform(id: "instagram", name: "Instagram", color: Color(hex: 0xe1_306c),
                 hint: "instagram username"),
        Platform(id: "whatsapp", name: "WhatsApp", color: Color(hex: 0x25_d366),
                 hint: "phone with country code"),
        Platform(id: "telegram", name: "Telegram", color: Color(hex: 0x22_9ed9),
                 hint: "telegram username"),
        Platform(id: "messenger", name: "Messenger", color: Color(hex: 0x00_84ff),
                 hint: "facebook profile id"),
        // X is black on white and white on black; a fixed brand grey would vanish into whichever
        // one it lands on.
        Platform(id: "x", name: "X", color: Ink.ink, hint: "x username"),
        Platform(id: "discord", name: "Discord", color: Color(hex: 0x58_65f2),
                 hint: "discord username"),
    ]

    static func named(_ id: String) -> Platform? { all.first { $0.id == id } }

    /// How the address reads to a human: @maya everywhere, +49… on WhatsApp.
    func display(_ handle: String) -> String { isPhone ? "+\(handle)" : "@\(handle)" }

    /// The link that opens a conversation with them in that app — the whole point of listing an
    /// address. nil where the platform has no addressable link for a bare handle (Discord routes by
    /// a numeric user id we deliberately do not collect), and the UI then offers a copy instead of a
    /// button that would go nowhere.
    func chatURL(_ handle: String) -> URL? {
        switch id {
        case "instagram": URL(string: "https://ig.me/m/\(handle)")
        case "whatsapp": URL(string: "https://wa.me/\(handle)")
        case "telegram": URL(string: "https://t.me/\(handle)")
        case "messenger": URL(string: "https://m.me/\(handle)")
        case "x": URL(string: "https://x.com/\(handle)")
        default: nil
        }
    }

    /// X's link lands on a profile, not a conversation. Say what the button actually does.
    var linkOpensChat: Bool { id != "x" }

    func linkLabel(_ handle: String) -> String { linkOpensChat ? "Message" : "Open" }
}

// MARK: - Pieces

/// The app's official brand-mark tile. It uses the same Simple Icons paths and brand colours as
/// the Chrome popup; colour stays quiet enough that six rows still read as one list.
struct PlatformMark: View {
    let platform: Platform
    var size: CGFloat = 30

    var body: some View {
        Image(platform.iconAsset)
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.56, height: size * 0.56)
            .foregroundStyle(platform.color)
            .frame(width: size, height: size)
            .background(platform.color.opacity(0.14), in: .rect(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

/// One address, with the way in. This row IS the product's promise made concrete: a private
/// identity, and the ordinary app you already talk to them in, on the same line.
struct AddressRow: View {
    let platform: Platform
    let handle: String

    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            PlatformMark(platform: platform)

            VStack(alignment: .leading, spacing: 2) {
                Text(platform.name)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.ink)
                Text(platform.display(handle))
                    .font(.machine(13))
                    .foregroundStyle(Ink.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let url = platform.chatURL(handle) {
                Link(destination: url) {
                    Text(platform.linkLabel(handle))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Ink.accentDeep)
                }
                .accessibilityLabel("\(platform.linkLabel(handle)) \(platform.display(handle)) on \(platform.name)")
            } else {
                Button {
                    UIPasteboard.general.string = platform.display(handle)
                    copied = true
                } label: {
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(copied ? Ink.muted : Ink.accentDeep)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy their \(platform.name) handle")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - People

/// Initials in a circle, in a colour derived from the handle — so @maya is the same hue here, on her
/// profile, and in the extension's contact list. The palette is the one in src/popup/popup.ts;
/// keeping the two in step costs nothing and makes one person look like one person everywhere.
struct PersonAvatar: View {
    let handle: String
    var size: CGFloat = 36

    private static let palette: [Color] = [
        Color(hex: 0xff_5f52), Color(hex: 0x57_c088), Color(hex: 0xd9_a13d),
        Color(hex: 0x5b_9df0), Color(hex: 0x5b_b8c4), Color(hex: 0xb9_8cf0),
    ]

    /// Same hash as the popup's avatarColor(), so the two surfaces agree.
    private var color: Color {
        var h: UInt32 = 0
        for byte in handle.unicodeScalars { h = h &* 31 &+ byte.value }
        return Self.palette[Int(h % UInt32(Self.palette.count))]
    }

    private var initials: String {
        let letters = handle.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(2)).uppercased()
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.36, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: .circle)
            .overlay(Circle().strokeBorder(color.opacity(0.3), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// One person, in a list. Tapping it opens who they are; it never acts on them by itself — an
/// accept or a disconnect happens on the profile, where the consequence is spelled out.
struct PersonRow: View {
    let handle: String
    var subtitle: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            PersonAvatar(handle: handle)

            VStack(alignment: .leading, spacing: 2) {
                Text("@\(handle)")
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.muted)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .contentShape(.rect)
    }
}
