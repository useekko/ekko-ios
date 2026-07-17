import SwiftUI
import UIKit

/// The clean-room, production keyboard plane shared by Ekko and KeyboardLab.
///
/// KeyboardLab renders this exact type next to the current Apple keyboard. Keeping layout and
/// interaction here means a lab improvement cannot quietly diverge from the extension users run.
enum NativeKeyboardPlane: String, CaseIterable {
    case letters
    case numbers
    case symbols
    case emoji
}

enum NativeKeyboardReturnStyle {
    case standard
    case done
}

/// Public measurements exposed to the lab report. The values are intentionally few: every key
/// frame is derived from the keyboard bounds, so the same component adapts to each iPhone width.
enum NativeKeyboardMetrics {
    static let planeHeight: CGFloat = 225
    /// The current native Emoji input surface is 399pt on a portrait Pro Max: 53 search,
    /// 218 catalog, 60 category rail, and 68 footer.
    static let emojiPlaneHeight: CGFloat = 399
    static let horizontalInset: CGFloat = 20 / 3
    static let horizontalGap: CGFloat = 6
    static let verticalGap: CGFloat = 11
    static let keyHeight: CGFloat = 45
    static let cornerRadius: CGFloat = 6.75
    static let hitTop: CGFloat = 1
    static let hitLeading: CGFloat = 2
    static let hitBottom: CGFloat = 10
    static let hitTrailing: CGFloat = 4
}

struct NativeKeyPlaneView: View {
    @Binding var plane: NativeKeyboardPlane
    @Binding var shifted: Bool
    @Binding var capsLock: Bool

    var showsGlobe: Bool
    var showsEmoji: Bool
    var returnStyle: NativeKeyboardReturnStyle = .standard
    var onText: (String) -> Void
    var onBackspace: () -> Void
    var onNextKeyboard: () -> Void

    @State private var lastShiftTapAt: TimeInterval?

    var body: some View {
        Group {
            if plane == .emoji {
                NativeEmojiPlaneView(
                    plane: $plane,
                    showsGlobe: showsGlobe,
                    onText: onText,
                    onBackspace: onBackspace,
                    onNextKeyboard: onNextKeyboard
                )
            } else {
                GeometryReader { geometry in
                    let keys = NativeKeyboardLayout.keys(
                        in: geometry.size,
                        plane: plane,
                        shifted: shifted || capsLock,
                        capsLock: capsLock,
                        showsGlobe: showsGlobe,
                        showsEmoji: showsEmoji,
                        returnStyle: returnStyle
                    )

                    ZStack(alignment: .topLeading) {
                        ForEach(keys) { key in
                            NativeKeyCap(key: key) {
                                activate(key.action)
                            }
                            .offset(
                                x: key.frame.minX - NativeKeyboardMetrics.hitLeading,
                                y: key.frame.minY - NativeKeyboardMetrics.hitTop
                            )
                        }
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .topLeading
                    )
                }
            }
        }
        .frame(
            height: plane == .emoji
                ? NativeKeyboardMetrics.emojiPlaneHeight
                : NativeKeyboardMetrics.planeHeight
        )
    }

    private func activate(_ action: NativeKeyboardKey.Action) {
        switch action {
        case .text(let text):
            lastShiftTapAt = nil
            onText(text)
        case .backspace:
            onBackspace()
        case .shift:
            toggleShift()
        case .plane(let destination):
            lastShiftTapAt = nil
            plane = destination
        case .nextKeyboard:
            lastShiftTapAt = nil
            onNextKeyboard()
        }
    }

    /// Apple's Shift is one-shot on a single tap and locks only on a prompt second tap. Tracking
    /// the actual tap interval also means the automatic sentence-start Shift can be turned off
    /// with one tap instead of accidentally becoming Caps Lock.
    private func toggleShift() {
        let now = ProcessInfo.processInfo.systemUptime
        if capsLock {
            capsLock = false
            shifted = false
            lastShiftTapAt = nil
        } else if shifted {
            if let previous = lastShiftTapAt, now - previous <= 0.42 {
                capsLock = true
                shifted = true
            } else {
                shifted = false
            }
            lastShiftTapAt = nil
        } else {
            shifted = true
            lastShiftTapAt = now
        }
    }
}

// MARK: - Layout

private struct NativeKeyboardKey: Identifiable {
    enum Action {
        case text(String)
        case backspace
        case shift
        case plane(NativeKeyboardPlane)
        case nextKeyboard
    }

    enum Surface {
        case character
        case modifier
        case action
    }

    let id: String
    let label: String?
    let symbol: String?
    let spoken: String
    let action: Action
    let surface: Surface
    let active: Bool
    let repeats: Bool
    let frame: CGRect

    var showsPreview: Bool {
        guard case .text(let value) = action else { return false }
        return value.count == 1 && value != " " && value != "\n"
    }
}

private enum NativeKeyboardLayout {
    private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let numbers = ["1234567890", "-/:;()$&@\"", ".,?!'"]
    private static let symbols = ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]

    static func keys(
        in size: CGSize,
        plane: NativeKeyboardPlane,
        shifted: Bool,
        capsLock: Bool,
        showsGlobe: Bool,
        showsEmoji: Bool,
        returnStyle: NativeKeyboardReturnStyle
    ) -> [NativeKeyboardKey] {
        guard size.width > 0, size.height > 0 else { return [] }

        let side = NativeKeyboardMetrics.horizontalInset
        let gap = NativeKeyboardMetrics.horizontalGap
        let rowGap = NativeKeyboardMetrics.verticalGap
        let keyHeight = min(
            NativeKeyboardMetrics.keyHeight,
            max(1, (size.height - rowGap * 3 - 12) / 4)
        )
        let top = min(8, max(4, size.height - keyHeight * 4 - rowGap * 3 - 4))
        let unit = max(1, (size.width - side * 2 - gap * 9) / 10)
        let rows: [String]
        switch plane {
        case .letters: rows = letters
        case .numbers: rows = numbers
        case .symbols: rows = symbols
        case .emoji: return []
        }

        var result: [NativeKeyboardKey] = []

        // Character rows are centered independently, like Apple's staggered QWERTY rows. The
        // modifier keys on row three stay pinned to the outer edge instead of pushing punctuation
        // inward on the number and symbol planes.
        for rowIndex in 0..<3 {
            let characters = Array(rows[rowIndex])
            let usesWidePunctuationKeys = rowIndex == 2 && plane != .letters
            let thirdRowInset = (size.width - (unit * 7 + gap * 6)) / 2
            let characterWidth = usesWidePunctuationKeys
                ? (size.width - thirdRowInset * 2 - gap * CGFloat(characters.count - 1))
                    / CGFloat(characters.count)
                : unit
            let contentWidth = characterWidth * CGFloat(characters.count)
                + gap * CGFloat(characters.count - 1)
            let originX = (size.width - contentWidth) / 2
            let y = top + CGFloat(rowIndex) * (keyHeight + rowGap)

            for (column, character) in characters.enumerated() {
                let raw = String(character)
                let display = plane == .letters && shifted ? raw.uppercased() : raw
                result.append(
                    NativeKeyboardKey(
                        id: "row-\(rowIndex)-\(column)-\(raw)",
                        label: display,
                        symbol: nil,
                        spoken: display,
                        action: .text(display),
                        surface: .character,
                        active: false,
                        repeats: false,
                        frame: CGRect(
                            x: originX + CGFloat(column) * (characterWidth + gap),
                            y: y,
                            width: characterWidth,
                            height: keyHeight
                        )
                    )
                )
            }
        }

        let thirdY = top + 2 * (keyHeight + rowGap)
        let modifierWidth: CGFloat = 50
        let leadingLabel: String?
        let leadingSymbol: String?
        let leadingSpoken: String
        let leadingAction: NativeKeyboardKey.Action
        let leadingActive: Bool
        switch plane {
        case .letters:
            leadingLabel = nil
            leadingSymbol = capsSymbol(shifted: shifted, capsLock: capsLock)
            leadingSpoken = "Shift"
            leadingAction = .shift
            leadingActive = shifted
        case .numbers:
            leadingLabel = "#+="
            leadingSymbol = nil
            leadingSpoken = "symbols"
            leadingAction = .plane(.symbols)
            leadingActive = false
        case .symbols:
            leadingLabel = "123"
            leadingSymbol = nil
            leadingSpoken = "numbers"
            leadingAction = .plane(.numbers)
            leadingActive = false
        case .emoji:
            return []
        }
        result.append(
            NativeKeyboardKey(
                id: "third-leading",
                label: leadingLabel,
                symbol: leadingSymbol,
                spoken: leadingSpoken,
                action: leadingAction,
                surface: .modifier,
                active: leadingActive,
                repeats: false,
                frame: CGRect(x: side, y: thirdY, width: modifierWidth, height: keyHeight)
            )
        )
        result.append(
            NativeKeyboardKey(
                id: "delete",
                label: nil,
                symbol: "delete.left",
                spoken: "Delete",
                action: .backspace,
                surface: .modifier,
                active: false,
                repeats: true,
                frame: CGRect(
                    x: size.width - side - modifierWidth,
                    y: thirdY,
                    width: modifierWidth,
                    height: keyHeight
                )
            )
        )

        let bottomY = top + 3 * (keyHeight + rowGap)
        let hasUtilityKeys = showsEmoji || showsGlobe
        let planeWidth: CGFloat = hasUtilityKeys ? 54 : 102
        let emojiWidth: CGFloat = showsEmoji ? 50 : 0
        let globeWidth: CGFloat = showsGlobe ? 50 : 0
        let returnWidth: CGFloat = 102
        let utilityWidth = (showsEmoji ? emojiWidth + gap : 0)
            + (showsGlobe ? globeWidth + gap : 0)
        let spaceX = side + planeWidth + gap + utilityWidth
        let returnX = size.width - side - returnWidth
        let spaceWidth = max(unit, returnX - gap - spaceX)

        result.append(
            NativeKeyboardKey(
                id: "plane-toggle",
                label: plane == .letters ? "123" : "ABC",
                symbol: nil,
                spoken: plane == .letters ? "numbers" : "letters",
                action: .plane(plane == .letters ? .numbers : .letters),
                surface: .modifier,
                active: false,
                repeats: false,
                frame: CGRect(x: side, y: bottomY, width: planeWidth, height: keyHeight)
            )
        )

        var nextUtilityX = side + planeWidth + gap
        if showsEmoji {
            result.append(
                NativeKeyboardKey(
                    id: "emoji",
                    label: nil,
                    symbol: "face.smiling",
                    spoken: "Emoji",
                    action: .plane(.emoji),
                    surface: .modifier,
                    active: false,
                    repeats: false,
                    frame: CGRect(
                        x: nextUtilityX,
                        y: bottomY,
                        width: emojiWidth,
                        height: keyHeight
                    )
                )
            )
            nextUtilityX += emojiWidth + gap
        }

        if showsGlobe {
            result.append(
                NativeKeyboardKey(
                    id: "next-keyboard",
                    label: nil,
                    symbol: "globe",
                    spoken: "Next keyboard",
                    action: .nextKeyboard,
                    surface: .modifier,
                    active: false,
                    repeats: false,
                    frame: CGRect(
                        x: nextUtilityX,
                        y: bottomY,
                        width: globeWidth,
                        height: keyHeight
                    )
                )
            )
        }

        result.append(
            NativeKeyboardKey(
                id: "space",
                label: nil,
                symbol: nil,
                spoken: "Space",
                action: .text(" "),
                surface: .character,
                active: false,
                repeats: false,
                frame: CGRect(x: spaceX, y: bottomY, width: spaceWidth, height: keyHeight)
            )
        )
        result.append(
            NativeKeyboardKey(
                id: "return",
                label: nil,
                symbol: returnStyle == .done ? "checkmark" : "return",
                spoken: returnStyle == .done ? "Done" : "Return",
                action: .text("\n"),
                surface: returnStyle == .done ? .action : .modifier,
                active: false,
                repeats: false,
                frame: CGRect(x: returnX, y: bottomY, width: returnWidth, height: keyHeight)
            )
        )

        return result
    }

    private static func capsSymbol(shifted: Bool, capsLock: Bool) -> String {
        if capsLock { return "capslock.fill" }
        return shifted ? "shift.fill" : "shift"
    }
}

// MARK: - Key rendering and input

private struct NativeKeyCap: View {
    let key: NativeKeyboardKey
    let action: () -> Void

    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        visual
            .frame(width: key.frame.width, height: key.frame.height)
            .padding(
                EdgeInsets(
                    top: NativeKeyboardMetrics.hitTop,
                    leading: NativeKeyboardMetrics.hitLeading,
                    bottom: NativeKeyboardMetrics.hitBottom,
                    trailing: NativeKeyboardMetrics.hitTrailing
                )
            )
            .foregroundStyle(key.surface == .action ? Color.white : Ink.keyboardInk)
            .contentShape(Rectangle())
            .zIndex(pressed ? 20 : 0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged(handleDrag)
                    .onEnded(handleRelease)
            )
            .onDisappear { stopPress() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(key.spoken)
            .accessibilityIdentifier(key.spoken)
            .accessibilityAddTraits([.isKeyboardKey, .isButton])
            .accessibilityAction { action() }
    }

    private var visual: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NativeKeyboardMetrics.cornerRadius, style: .continuous)
                .fill(pressed ? Ink.keyPressed : fill)

            if let symbol = key.symbol {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize(symbol), weight: .regular))
                    .symbolRenderingMode(.monochrome)
            } else if let label = key.label {
                Text(label)
                    .font(font(for: label))
            }

            if pressed, key.showsPreview, let label = key.label {
                keyPreview(label)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    private var hitBounds: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: key.frame.width + NativeKeyboardMetrics.hitLeading
                + NativeKeyboardMetrics.hitTrailing,
            height: key.frame.height + NativeKeyboardMetrics.hitTop
                + NativeKeyboardMetrics.hitBottom
        )
    }

    private func handleDrag(_ value: DragGesture.Value) {
        let acceptsTouch = hitBounds.insetBy(dx: -8, dy: -8).contains(value.location)
        if acceptsTouch, !pressed {
            pressed = true
            if key.repeats {
                action()
                startRepeat()
            }
        } else if !acceptsTouch, pressed {
            stopPress()
        }
    }

    private func handleRelease(_ value: DragGesture.Value) {
        let shouldActivate = pressed
            && !key.repeats
            && hitBounds.insetBy(dx: -8, dy: -8).contains(value.location)
        stopPress()
        if shouldActivate { action() }
    }

    private var fill: Color {
        switch key.surface {
        case .character:
            return Ink.key
        case .modifier:
            return key.active ? Ink.key : Ink.keyModifier
        case .action:
            return Ink.keyboardAction
        }
    }

    private func font(for label: String) -> Font {
        if key.id == "space" || key.id == "return" || label.count > 2 {
            return .system(size: 16, weight: .regular)
        }
        return .system(size: 24, weight: .regular)
    }

    private func symbolSize(_ symbol: String) -> CGFloat {
        switch symbol {
        case "globe", "face.smiling": 19
        case "return", "checkmark": 24
        case "shift", "shift.fill": 22
        default: 21
        }
    }

    private func keyPreview(_ label: String) -> some View {
        VStack(spacing: -5) {
            Text(label)
                .font(.system(size: 31, weight: .regular))
                .frame(width: max(54, key.frame.width + 18), height: 57)
                .background(fill, in: .rect(cornerRadius: 7, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(fill)
                .frame(width: min(25, key.frame.width - 6), height: 12)
        }
        .offset(y: -key.frame.height - 19)
    }

    private func startRepeat() {
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(430))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(55))
            }
        }
    }

    private func stopPress() {
        pressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}
