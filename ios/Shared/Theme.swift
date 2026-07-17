import SwiftUI

// The DESIGN.md token set, in Swift. Shared by the app and the keyboard extension so a "sealed"
// accent means the same colour in both.
//
// The app and the keyboard both follow the system appearance: every token carries the light and
// the dark column and resolves from the trait environment. The accent is coral — the Balanced
// Packet E mark's own colour, the sole accent since 2026-07 (the old indigo is retired).

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

private func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(
        UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
}

enum Ink {
    static let bg = dynamic(light: 0xf6_f7fb, dark: 0x0a_0c11)
    static let ink = dynamic(light: 0x14_161d, dark: 0xed_eef4)
    static let inkSoft = dynamic(light: 0x36_3a46, dark: 0xc9_ccd6)
    static let muted = dynamic(light: 0x6d_7382, dark: 0x83_8896)
    static let faint = dynamic(light: 0xa9_aebc, dark: 0x5b_6070)
    static let line = dynamic(light: 0xe4_e7ef, dark: 0x22_2633)
    static let danger = dynamic(light: 0xb4_2318, dark: 0xff_7168)
    static let warning = dynamic(light: 0xb5_4708, dark: 0xff_ad45)
    /// Fills, rings, control tints, the CTA. Coral in both columns (DESIGN.md).
    static let accent = Color(hex: 0xff_5f52)
    static let accentInk = Color(hex: 0xff_ffff)
    /// Small accent TEXT and icons (< ~18px). Pure coral fails AA on light paper, so the light
    /// column deepens it — the popup's `--accent-deep`. In dark the two are the same colour.
    static let accentDeep = dynamic(light: 0xd6_3d30, dark: 0xff_5f52)

    /// Ekko coral: the mark plus active keyboard/sealing states. Same as `accent` now that coral
    /// is the sole accent; the keyboard keeps its own name for it.
    static let coral = Color(hex: 0xff_5f52)
    static let coralInk = Color(hex: 0x35_1110)

    /// A raised surface on `bg` — cards, the keyboard's own chrome.
    static let surface = dynamic(light: 0xff_ffff, dark: 0x12_151d)
    /// Keyboard-only neutrals track the native iOS keyboard instead of importing the app's
    /// blue-black card palette into a system surface. Coral remains the single Ekko affordance.
    static let keyboardInk = dynamic(light: 0x00_0000, dark: 0xff_ffff)
    static let keyboardMuted = dynamic(light: 0x63_6366, dark: 0x8e_8e93)
    static let keyboardLine = dynamic(light: 0xc7_c9cd, dark: 0x32_3232)
    /// Measured from the iOS 26.3 Apple keyboard in KeyboardLab. Unlike older iOS releases,
    /// modifier and character caps now share one surface in both appearances.
    static let key = dynamic(light: 0xff_ffff, dark: 0x3d_3d3d)
    static let keyModifier = dynamic(light: 0xff_ffff, dark: 0x3d_3d3d)
    static let keyPressed = dynamic(light: 0xd3_d5d9, dark: 0x57_5757)
    static let keyBacking = dynamic(light: 0xe2_e4e8, dark: 0x17_1717)
    static let keyboardChrome = dynamic(light: 0xe2_e4e8, dark: 0x17_1717)
    /// Plaintext opens on an opaque system-neutral surface, never onto the host app.
    static let readerBacking = dynamic(light: 0xfa_fafa, dark: 0x1c_1c1e)
}

extension Font {
    /// Headlines and editorial lines. New York is the native serif — Newsreader's role on iOS.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Machine output ONLY: ciphertext, safety numbers, the 24 words. Never a label.
    static func machine(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Kickers and micro-labels: uppercase, tracked, never mono (DESIGN.md).
    static var kicker: Font { .system(size: 11, weight: .medium) }
}

extension View {
    /// Uppercase, letter-spaced section label.
    func kickerStyle() -> some View {
        self.font(.kicker)
            .textCase(.uppercase)
            .tracking(1.3)
            .foregroundStyle(Ink.muted)
    }

    /// The glass card: translucent surface, hairline, tinted shadow (never plain black).
    func card(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .background(Ink.surface, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.line, lineWidth: 1))
            .shadow(color: Color(hex: 0x0a_1030).opacity(0.18), radius: 18, y: 8)
    }
}

/// The primary action. The site's glossy coral CTA: lit from above, pure coral by two thirds
/// down, a coral-tinted shadow underneath. The one loud thing on a screen.
struct AccentButton: ButtonStyle {
    var wide = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Ink.accentInk)
            .frame(maxWidth: wide ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, wide ? 0 : 20)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0xff_756a), location: 0),
                        .init(color: Ink.accent, location: 0.62),
                    ],
                    startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: 13)
            )
            .shadow(color: Ink.accent.opacity(0.35), radius: 9, y: 5)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Secondary action: hairline pill, no fill.
///
/// `wide` is not decoration. A `.frame(maxWidth: .infinity)` applied AFTER `.buttonStyle()` stretches
/// the button's frame but not the styled pill inside it, so the pill stays hugged to its text and
/// floats in the middle — which is what every stacked secondary button in this app was doing. The
/// width has to be set on the label, before the background, which is what this does. Inline buttons
/// (next to a text field, inside a row) must keep hugging, so it stays off by default.
struct QuietButton: ButtonStyle {
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Ink.inkSoft)
            .frame(maxWidth: wide ? .infinity : nil)
            .padding(.vertical, 11)
            .padding(.horizontal, 16)
            .background(Ink.surface, in: .rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Ink.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
