import SwiftUI

/// Clean-room Emoji surface shared by KeyboardLab and the shipping extension.
///
/// Apple exposes Emoji as a separate public input mode, but an extension cannot jump directly to
/// that mode—the only public system action is "advance to next keyboard." Keeping Emoji in Ekko
/// makes the result deterministic while preserving the system globe below the extension.
struct NativeEmojiPlaneView: View {
    @Binding var plane: NativeKeyboardPlane

    let showsGlobe: Bool
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onNextKeyboard: () -> Void

    @AppStorage("app.useekko.keyboard.recent-emojis") private var storedRecents = ""
    @State private var category = NativeEmojiCategory.recent
    @State private var searchActive = false
    @State private var searchQuery = ""
    @State private var searchPlane = NativeKeyboardPlane.letters
    @State private var searchShifted = false
    @State private var searchCapsLock = false
    @State private var tonePicker: NativeEmojiTonePicker?

    var body: some View {
        Group {
            if searchActive {
                searchSurface
            } else {
                browseSurface
            }
        }
        // UIInputView centers oversized content in the 34pt home-indicator safe area. Apple's
        // Emoji surface consumes that footer area instead; the measured half-inset restores the
        // public 567/610/831/887.7pt landmarks inside a 399pt input view.
        .offset(y: 17)
        .frame(height: NativeKeyboardMetrics.emojiPlaneHeight)
        .background(Ink.keyBacking)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var browseSurface: some View {
        ZStack(alignment: .topLeading) {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    searchBar
                    emojiCatalog
                    categoryRail(proxy: proxy)
                    footer
                }
            }

            if let tonePicker {
                tonePickerOverlay(tonePicker)
            }
        }
        .coordinateSpace(name: "emoji-plane")
    }

    /// Apple's search assistant is 53pt high: a 422x40 field at x=9/y=10. Tapping it enters a
    /// local input state, so search text can never leak into the host composer.
    private var searchBar: some View {
        Button {
            searchActive = true
            searchPlane = .letters
            searchShifted = false
            searchCapsLock = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                Text("Search Emoji")
                    .font(.system(size: 18, weight: .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.emojiSearchInk)
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Ink.emojiSearch, in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .accessibilityLabel("Search Emoji")
        .accessibilityIdentifier("emoji-search")
    }

    /// Search mirrors the public Emoji transition: 97pt of field/results, the native-sized
    /// 232pt QWERTY region, and the 70pt input-mode footer.
    private var searchSurface: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                activeSearchBar
                searchResults
                    .padding(.top, 3)
            }
            .frame(height: 97, alignment: .top)

            NativeKeyPlaneView(
                plane: $searchPlane,
                shifted: $searchShifted,
                capsLock: $searchCapsLock,
                showsGlobe: false,
                showsEmoji: false,
                returnStyle: .done,
                onText: handleSearchKey,
                onBackspace: deleteSearchCharacter,
                onNextKeyboard: {}
            )
            .frame(height: 232, alignment: .top)

            searchFooter
        }
    }

    private var activeSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Ink.emojiSearchInk)

            HStack(spacing: 0) {
                if searchQuery.isEmpty {
                    searchCaret
                    Text("Search Emoji")
                        .foregroundStyle(Ink.emojiSearchInk)
                } else {
                    Text(searchQuery)
                        .foregroundStyle(Ink.keyboardInk)
                    searchCaret
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 18, weight: .regular))
            .frame(maxWidth: .infinity, alignment: .leading)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Ink.emojiSearchInk)
                        .frame(width: 22, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear text")
                .accessibilityIdentifier("emoji-search-clear")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(Ink.emojiSearch, in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { searchActive = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search Emoji")
        .accessibilityValue(searchQuery)
        .accessibilityIdentifier("emoji-search-active")
        .padding(.horizontal, 9)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private var searchCaret: some View {
        Rectangle()
            .fill(Color(hex: 0x0a_84ff))
            .frame(width: 2, height: 22)
    }

    private var searchResults: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(searchMatches.enumerated()), id: \.offset) { _, emoji in
                    Button {
                        insert(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                            .frame(width: 107, height: 41)
                            .contentShape(.rect)
                    }
                    .buttonStyle(NativeEmojiCellButtonStyle())
                    .accessibilityLabel(emoji)
                    .accessibilityIdentifier("emoji-search-result-\(emoji)")
                    .accessibilityAddTraits(.isKeyboardKey)
                    .accessibilityRemoveTraits(.isButton)
                }
            }
            .padding(.leading, 8)
        }
        .scrollIndicators(.hidden)
        .frame(height: 41)
    }

    private var searchFooter: some View {
        HStack(spacing: 0) {
            Button {
                searchActive = false
                searchQuery = ""
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 29, weight: .regular))
                    .foregroundStyle(Ink.emojiFooterInk)
                    .frame(width: 80, height: 69)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Emoji")
            .accessibilityIdentifier("emoji-search-close")

            Spacer(minLength: 0)

            if showsGlobe {
                Button(action: onNextKeyboard) {
                    Image(systemName: "globe")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(Ink.emojiFooterInk)
                        .frame(width: 80, height: 69)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next keyboard")
                .accessibilityIdentifier("emoji-next-keyboard")
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 70)
    }

    private var searchMatches: [String] {
        NativeEmojiCatalog.search(searchQuery)
    }

    private func handleSearchKey(_ value: String) {
        if value == "\n" {
            searchActive = false
            searchQuery = ""
            return
        }
        searchQuery.append(contentsOf: value.lowercased())
        if searchShifted && !searchCapsLock { searchShifted = false }
    }

    private func deleteSearchCharacter() {
        guard !searchQuery.isEmpty else {
            searchActive = false
            return
        }
        searchQuery.removeLast()
    }

    /// One continuous sectioned collection, matching the native surface. A swipe can cross from
    /// Frequently Used into Smileys and onward; section headers move with their Emoji instead of
    /// being replaced by a fixed app-style title.
    private var emojiCatalog: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(NativeEmojiCategory.allCases) { item in
                    NativeEmojiSection(
                        category: item,
                        emojis: emojis(for: item),
                        onText: insert,
                        onLongPress: presentTonePicker
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 218)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .coordinateSpace(name: "emoji-catalog")
        .onPreferenceChange(NativeEmojiSectionOffsetKey.self) { offsets in
            guard !offsets.isEmpty else { return }
            let passed = offsets.filter { $0.value <= 14 }
            let visible = passed.max(by: { $0.value < $1.value })
                ?? offsets.min(by: { abs($0.value) < abs($1.value) })
            if let visible, visible.key != category {
                category = visible.key
            }
        }
        .accessibilityLabel("Emoji")
    }

    private func presentTonePicker(emoji: String, frame: CGRect) {
        guard let variants = NativeEmojiCatalog.toneVariants(for: emoji) else { return }
        tonePicker = NativeEmojiTonePicker(
            variants: variants,
            sourceFrame: frame
        )
    }

    private func tonePickerOverlay(_ picker: NativeEmojiTonePicker) -> some View {
        GeometryReader { geometry in
            let width: CGFloat = 282
            let barHeight: CGFloat = 56
            let margin: CGFloat = 10
            let centerX = min(
                geometry.size.width - width / 2 - margin,
                max(width / 2 + margin, picker.sourceFrame.midX)
            )
            // The system keeps the palette in the search strip and grows its pointer toward the
            // pressed row, which avoids covering neighboring Emoji regardless of row.
            let barY: CGFloat = 12
            let tailHeight = max(22, picker.sourceFrame.midY - barY - barHeight + 4)

            ZStack(alignment: .topLeading) {
                Ink.keyBacking.opacity(0.82)
                    .contentShape(.rect)
                    .onTapGesture { tonePicker = nil }

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Ink.key)
                    .frame(width: 40, height: tailHeight)
                    .position(
                        x: picker.sourceFrame.midX,
                        y: barY + barHeight + tailHeight / 2 - 4
                    )
                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1)

                HStack(spacing: 0) {
                    ForEach(Array(picker.variants.enumerated()), id: \.offset) { index, emoji in
                        Button {
                            insert(emoji)
                            tonePicker = nil
                        } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(width: 45, height: barHeight)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(emoji)
                        .accessibilityIdentifier("emoji-tone-\(emoji)")
                        .accessibilityAddTraits(.isKeyboardKey)

                        if index == 0 {
                            Rectangle()
                                .fill(Ink.keyboardLine.opacity(0.45))
                                .frame(width: 1, height: 32)
                        }
                    }
                }
                .padding(.horizontal, 5.5)
                .frame(width: width, height: barHeight)
                .background(Ink.key, in: .rect(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .position(x: centerX, y: barY + barHeight / 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skin tone")
        .accessibilityIdentifier("emoji-tone-picker")
    }

    private func categoryRail(proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Native category hit regions overlap by roughly one point while their centers keep
            // a 39.5pt cadence. The negative spacing reproduces both the public AX frames and the
            // forgiving touch targets instead of leaving hairline dead strips between buttons.
            HStack(spacing: -1) {
                ForEach(NativeEmojiCategory.allCases) { item in
                    Button {
                        category = item
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(item.anchorID, anchor: .leading)
                        }
                    } label: {
                        NativeEmojiCategoryGlyph(category: item)
                            .foregroundStyle(
                                category == item
                                    ? Ink.emojiCategorySelected : Ink.emojiCategoryIdle
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 37)
                            .background {
                                if category == item {
                                    Circle().fill(Ink.emojiSelection)
                                        .frame(width: 30, height: 30)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.title) category")
                    .accessibilityIdentifier("emoji-category-\(item.rawValue)")
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
            .frame(width: 365, height: 50, alignment: .top)
            .padding(.top, 5)
            .padding(.leading, 14.6666666667)

            NativeEmojiDeleteButton(action: onBackspace)
                .frame(width: 57, height: 50)
                .padding(.leading, 3)
        }
        .padding(.top, 3)
        .frame(height: 60, alignment: .top)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button { plane = .letters } label: {
                Text("ABC")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Ink.emojiFooterInk)
                    .frame(width: 80, height: 68)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next keyboard")
            .accessibilityValue("Ekko English")
            .accessibilityIdentifier("emoji-letters")

            Spacer(minLength: 0)

            if showsGlobe {
                Button(action: onNextKeyboard) {
                    Image(systemName: "globe")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(Ink.emojiFooterInk)
                        .frame(width: 80, height: 68)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next keyboard")
                .accessibilityIdentifier("emoji-next-keyboard")
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 68)
    }

    private func emojis(for item: NativeEmojiCategory) -> [String] {
        if item == .recent {
            var result = storedRecents
                .split(separator: "\u{001F}")
                .map(String.init)
                .filter { !$0.isEmpty }
            result = Array(result.prefix(30))
            for emoji in NativeEmojiCatalog.frequentlyUsed where !result.contains(emoji) {
                guard result.count < 30 else { break }
                result.append(emoji)
            }
            return result
        }
        return NativeEmojiCatalog.emojis(for: item)
    }

    private func insert(_ emoji: String) {
        onText(emoji)
        var recent = storedRecents
            .split(separator: "\u{001F}")
            .map(String.init)
        recent.removeAll { $0 == emoji }
        recent.insert(emoji, at: 0)
        storedRecents = recent.prefix(30).joined(separator: "\u{001F}")
    }
}

private struct NativeEmojiSection: View {
    let category: NativeEmojiCategory
    let emojis: [String]
    let onText: (String) -> Void
    let onLongPress: (String, CGRect) -> Void

    private let rows = Array(
        repeating: GridItem(.fixed(32), spacing: 8, alignment: .center),
        count: 5
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(category.title.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.emojiSectionLabel)
                .lineLimit(1)
                .padding(.leading, 14)
                .frame(height: 26, alignment: .leading)
                .id(category.anchorID)

            LazyHGrid(rows: rows, alignment: .center, spacing: 10) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, emoji in
                    NativeEmojiCell(
                        emoji: emoji,
                        action: { onText(emoji) },
                        onLongPress: { frame in onLongPress(emoji, frame) }
                    )
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 18)
            .frame(height: 192)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: NativeEmojiSectionOffsetKey.self,
                    value: [
                        category: geometry.frame(in: .named("emoji-catalog")).minX
                    ]
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(category.title)
    }
}

private struct NativeEmojiCategoryGlyph: View {
    let category: NativeEmojiCategory

    var body: some View {
        Group {
            switch category {
            case .smileys:
                NativeEmojiSmileyGlyph()
            case .animals:
                NativeEmojiBearGlyph()
            case .food:
                Image(systemName: "takeoutbag.and.cup.and.straw")
            case .travel:
                Image(systemName: "car")
            case .objects:
                Image(systemName: "lightbulb")
            case .symbols:
                VStack(spacing: -4) {
                    Text("♫")
                    Text("&%")
                }
                .font(.system(size: 9, weight: .semibold))
            case .flags:
                Image(systemName: "flag")
            default:
                Image(systemName: category.icon)
            }
        }
        .font(.system(size: 16, weight: .regular))
        .frame(width: 22, height: 22)
    }
}

private struct NativeEmojiSmileyGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.foreground, lineWidth: 1.35)
                .frame(width: 16, height: 16)

            Circle().fill(.foreground).frame(width: 1.7, height: 2.1)
                .offset(x: -3, y: -2.6)
            Circle().fill(.foreground).frame(width: 1.7, height: 2.1)
                .offset(x: 3, y: -2.6)

            Path { path in
                path.move(to: CGPoint(x: 4.5, y: 10))
                path.addLine(to: CGPoint(x: 13.5, y: 10))
                path.addCurve(
                    to: CGPoint(x: 4.5, y: 10),
                    control1: CGPoint(x: 12.4, y: 14.1),
                    control2: CGPoint(x: 5.6, y: 14.1)
                )
            }
            .stroke(.foreground, style: StrokeStyle(lineWidth: 1.15, lineJoin: .round))
            .frame(width: 18, height: 18)
        }
        .frame(width: 18, height: 18)
    }
}

private struct NativeEmojiBearGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.foreground, lineWidth: 1.4)
                .frame(width: 5.2, height: 5.2)
                .offset(x: -5.1, y: -5.2)
            Circle()
                .stroke(.foreground, lineWidth: 1.4)
                .frame(width: 5.2, height: 5.2)
                .offset(x: 5.1, y: -5.2)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.foreground, lineWidth: 1.4)
                .frame(width: 15, height: 14)
                .offset(y: 1.1)
            Circle().fill(.foreground).frame(width: 1.6, height: 1.6)
                .offset(x: -3.1, y: -1.3)
            Circle().fill(.foreground).frame(width: 1.6, height: 1.6)
                .offset(x: 3.1, y: -1.3)
            Ellipse()
                .stroke(.foreground, lineWidth: 1.1)
                .frame(width: 7, height: 5)
                .offset(y: 3.2)
            Circle().fill(.foreground).frame(width: 1.6, height: 1.4)
                .offset(y: 2.2)
        }
        .frame(width: 18, height: 18)
    }
}

private struct NativeEmojiSectionOffsetKey: PreferenceKey {
    static let defaultValue: [NativeEmojiCategory: CGFloat] = [:]

    static func reduce(
        value: inout [NativeEmojiCategory: CGFloat],
        nextValue: () -> [NativeEmojiCategory: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

private struct NativeEmojiCell: View {
    let emoji: String
    let action: () -> Void
    let onLongPress: (CGRect) -> Void

    @State private var suppressTap = false

    var body: some View {
        GeometryReader { geometry in
            Button {
                if suppressTap {
                    suppressTap = false
                } else {
                    action()
                }
            } label: {
                Text(emoji)
                    .font(.system(size: 30))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(NativeEmojiCellButtonStyle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.46, maximumDistance: 12)
                    .onEnded { _ in
                        guard NativeEmojiCatalog.toneVariants(for: emoji) != nil else { return }
                        suppressTap = true
                        onLongPress(geometry.frame(in: .named("emoji-plane")))
                    }
            )
            .accessibilityLabel(emoji)
            .accessibilityIdentifier("emoji-\(emoji)")
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityRemoveTraits(.isButton)
        }
        .frame(width: 32, height: 32)
    }
}

private struct NativeEmojiCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Ink.key.opacity(0.82) : .clear,
                in: .rect(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 1.16 : 1)
            .zIndex(configuration.isPressed ? 2 : 0)
    }
}

private struct NativeEmojiDeleteButton: View {
    let action: () -> Void

    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(Ink.emojiDeleteInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pressed ? Ink.keyPressed : .clear)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        startRepeat()
                    }
                    .onEnded { _ in stop() }
            )
            .onDisappear { stop() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("emoji-delete")
            .accessibilityAddTraits([.isKeyboardKey, .isButton])
            .accessibilityAction { action() }
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

    private func stop() {
        pressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}

private struct NativeEmojiTonePicker {
    let variants: [String]
    let sourceFrame: CGRect
}

private enum NativeEmojiCategory: String, CaseIterable, Identifiable {
    case recent
    case smileys
    case animals
    case food
    case activities
    case travel
    case objects
    case symbols
    case flags

    var id: String { rawValue }
    var anchorID: String { "emoji-section-\(rawValue)" }

    var title: String {
        switch self {
        case .recent: "Frequently Used"
        case .smileys: "Smileys & People"
        case .animals: "Animals & Nature"
        case .food: "Food & Drink"
        case .activities: "Activity"
        case .travel: "Travel & Places"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }

    var icon: String {
        switch self {
        case .recent: "clock"
        case .smileys: "face.smiling"
        case .animals: "pawprint"
        case .food: "takeoutbag.and.cup.and.straw"
        case .activities: "soccerball"
        case .travel: "car"
        case .objects: "lightbulb"
        case .symbols: "music.note.list"
        case .flags: "flag"
        }
    }
}

/// A deliberately static Unicode catalog: no network, no keyboard telemetry, and no dependency on
/// private Apple assets. Whitespace separates extended grapheme clusters, so joined sequences stay
/// one tappable Character when inserted into the host composer.
private enum NativeEmojiCatalog {
    static let frequentlyUsed = parse("""
        😂 ❤️ 😍 😊 😭 🙏 😘 🥰 😅 🔥 ✨ 🎉 👍 💕 🥹 😎 🤣 😁 😉 🤍 💀 👀 💯 😢 😡 🤗 🤔 🫶 👏 💪 ✅
        """)

    private static let smileys = parse("""
        😀 😃 😄 😁 😆 😅 😂 🤣 🥲 🥹 ☺️ 😊 😇 🙂 🙃 😉 😌 😍 🥰 😘 😗 😙 😚 😋 😛 😝 😜 🤪 🤨 🧐 🤓 😎 🥸 🤩 🥳 🙂‍↕️ 😏 😒 🙂‍↔️ 😞 😔 😟 😕 🙁 ☹️ 😣 😖 😫 😩 🥺 😢 😭 😮‍💨 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😶‍🌫️ 😱 😨 😰 😥 😓 🤗 🤔 🫣 🤭 🫢 🫡 🤫 🫠 🤥 😶 🫥 😐 🫤 😑 🫨 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😵 😵‍💫 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕 🤑 🤠 😈 👿 👹 👺 🤡 💩 👻 💀 ☠️ 👽 👾 🤖 🎃 😺 😸 😹 😻 😼 😽 🙀 😿 😾
        👋 🤚 🖐️ ✋ 🖖 🫱 🫲 🫳 🫴 👌 🤌 🤏 ✌️ 🤞 🫰 🤟 🤘 🤙 👈 👉 👆 🖕 👇 ☝️ 🫵 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 🫶 👐 🤲 🤝 🙏 ✍️ 💅 🤳 💪 🦾 🦿 🦵 🦶 👂 🦻 👃 🧠 🫀 🫁 🦷 🦴 👀 👁️ 👅 👄 🫦 💋 🩸 👶 🧒 👦 👧 🧑 👱 👨 🧔 👩 🧓 👴 👵 🙍 🙎 🙅 🙆 💁 🙋 🧏 🙇 🤦 🤷 🧑‍⚕️ 🧑‍🎓 🧑‍🏫 🧑‍⚖️ 🧑‍🌾 🧑‍🍳 🧑‍🔧 🧑‍🏭 🧑‍💼 🧑‍🔬 🧑‍💻 🧑‍🎤 🧑‍🎨 🧑‍✈️ 🧑‍🚀 🧑‍🚒 👮 🕵️ 💂 🥷 👷 🫅 🤴 👸 👳 👲 🧕 🤵 👰 🤰 🫃 🫄 🤱 👼 🎅 🤶 🧑‍🎄 🦸 🦹 🧙 🧚 🧛 🧜 🧝 🧞 🧟 💆 💇 🚶 🧍 🧎 🏃 💃 🕺 🕴️ 👯 🧖 🧗 🤺 🏇 ⛷️ 🏂 🏌️ 🏄 🚣 🏊 ⛹️ 🏋️ 🚴 🚵 🤸 🤼 🤽 🤾 🤹 🧘 🛀 🛌 👫 👭 👬 💏 💑 👪 🗣️ 👤 👥 🫂 👣
        """)

    private static let animals = parse("""
        🐵 🐒 🦍 🦧 🐶 🐕 🦮 🐕‍🦺 🐩 🐺 🦊 🦝 🐱 🐈 🐈‍⬛ 🦁 🐯 🐅 🐆 🐴 🫎 🫏 🐎 🦄 🦓 🦌 🦬 🐮 🐂 🐃 🐄 🐷 🐖 🐗 🐽 🐏 🐑 🐐 🐪 🐫 🦙 🦒 🐘 🦣 🦏 🦛 🐭 🐁 🐀 🐹 🐰 🐇 🐿️ 🦫 🦔 🦇 🐻 🐻‍❄️ 🐨 🐼 🦥 🦦 🦨 🦘 🦡 🐾 🦃 🐔 🐓 🐣 🐤 🐥 🐦 🐧 🕊️ 🦅 🦆 🦢 🦉 🦤 🪶 🦩 🦚 🦜 🪽 🐦‍⬛ 🪿 🐦‍🔥 🐸 🐊 🐢 🦎 🐍 🐲 🐉 🦕 🦖 🐳 🐋 🐬 🦭 🐟 🐠 🐡 🦈 🐙 🐚 🪸 🪼 🐌 🦋 🐛 🐜 🐝 🪲 🐞 🦗 🪳 🕷️ 🕸️ 🦂 🦟 🪰 🪱 🦠
        💐 🌸 💮 🪷 🏵️ 🌹 🥀 🌺 🌻 🌼 🌷 🪻 🌱 🪴 🌲 🌳 🌴 🌵 🌾 🌿 ☘️ 🍀 🍁 🍂 🍃 🪹 🪺 🍄 🍄‍🟫 🌰 🦀 🦞 🦐 🦑 🦪 🐌 🐞 🐝 🦋 🌍 🌎 🌏 🌐 🪨 🌙 ☀️ ⭐ 🌟 ✨ ⚡ ☄️ 💥 🔥 🌪️ 🌈 ☁️ 🌧️ ⛈️ 🌩️ 🌨️ ❄️ ☃️ ⛄ 🌬️ 💨 💧 💦 ☔ ☂️ 🌊
        """)

    private static let food = parse("""
        🍏 🍎 🍐 🍊 🍋 🍋‍🟩 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🫛 🥦 🥬 🥒 🌶️ 🫑 🌽 🥕 🫒 🧄 🧅 🥔 🍠 🫚 🫘 🥐 🥯 🍞 🥖 🫓 🥨 🧀 🥚 🍳 🧈 🥞 🧇 🥓 🥩 🍗 🍖 🦴 🌭 🍔 🍟 🍕 🫔 🌮 🌯 🥙 🧆 🥪 🥫 🍝 🍜 🍲 🍛 🍣 🍱 🥟 🦪 🍤 🍙 🍚 🍘 🍥 🥠 🥮 🍢 🍡 🍧 🍨 🍦 🥧 🧁 🍰 🎂 🍮 🍭 🍬 🍫 🍿 🍩 🍪 🌰 🥜 🍯
        🍼 🥛 ☕ 🫖 🍵 🍶 🍾 🍷 🍸 🍹 🍺 🍻 🥂 🥃 🫗 🥤 🧋 🧃 🧉 🧊 🥢 🍽️ 🍴 🥄 🔪 🫙 🏺 🥡 🧂 🥣 🥗 🍿 🫕 🥘 🍳 🧇 🥞
        """)

    private static let activities = parse("""
        ⚽ 🏀 🏈 ⚾ 🥎 🎾 🏐 🏉 🥏 🎱 🪀 🏓 🏸 🏒 🏑 🥍 🏏 🪃 🥅 ⛳ 🪁 🏹 🎣 🤿 🥊 🥋 🎽 🛹 🛼 🛷 ⛸️ 🥌 🎿 ⛷️ 🏂 🪂 🏋️ 🤼 🤸 ⛹️ 🤺 🤾 🏌️ 🏇 🧘 🏄 🏊 🤽 🚣 🧗 🚵 🚴 🏆 🥇 🥈 🥉 🏅 🎖️ 🏵️ 🎗️ 🎫 🎟️ 🎪 🤹 🎭 🩰 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🪘 🎷 🎺 🪗 🎸 🪕 🎻 🪈 🎲 ♟️ 🎯 🎳 🎮 🎰 🧩 🧸 🪅 🪩 🪆 🃏 🀄 🎴
        """)

    private static let travel = parse("""
        🚗 🚕 🚙 🚌 🚎 🏎️ 🚓 🚑 🚒 🚐 🛻 🚚 🚛 🚜 🦽 🦼 🛴 🚲 🛵 🏍️ 🛺 🚨 🚔 🚍 🚘 🚖 🚡 🚠 🚟 🚃 🚋 🚞 🚝 🚄 🚅 🚈 🚂 🚆 🚇 🚊 🚉 ✈️ 🛫 🛬 🛩️ 💺 🛰️ 🚀 🛸 🚁 🛶 ⛵ 🚤 🛥️ 🛳️ ⛴️ 🚢 ⚓ 🛟 🪝 ⛽ 🚧 🚦 🚥 🗺️ 🗿 🗽 🗼 🏰 🏯 🏟️ 🎡 🎢 🎠 ⛲ ⛱️ 🏖️ 🏝️ 🏜️ 🌋 ⛰️ 🏔️ 🗻 🏕️ ⛺ 🛖 🏠 🏡 🏘️ 🏚️ 🏗️ 🏭 🏢 🏬 🏣 🏤 🏥 🏦 🏨 🏪 🏫 🏩 💒 🏛️ ⛪ 🕌 🕍 🛕 🕋 ⛩️ 🛤️ 🛣️ 🌁 🌃 🏙️ 🌄 🌅 🌆 🌇 🌉 ♨️ 🎑 🏞️ 🌌 🌠 🎇 🎆 🧭 🧳
        """)

    private static let objects = parse("""
        ⌚ 📱 📲 💻 ⌨️ 🖥️ 🖨️ 🖱️ 🖲️ 🕹️ 🗜️ 💽 💾 💿 📀 📼 📷 📸 📹 🎥 📽️ 🎞️ 📞 ☎️ 📟 📠 📺 📻 🎙️ 🎚️ 🎛️ 🧭 ⏱️ ⏲️ ⏰ 🕰️ ⌛ ⏳ 📡 🔋 🪫 🔌 💡 🔦 🕯️ 🪔 🧯 🛢️ 💸 💵 💴 💶 💷 🪙 💰 💳 💎 ⚖️ 🪜 🧰 🪛 🔧 🔨 ⚒️ 🛠️ ⛏️ 🪚 🔩 ⚙️ 🪤 🧱 ⛓️ ⛓️‍💥 🧲 🔫 💣 🧨 🪓 🔪 🗡️ ⚔️ 🛡️ 🚬 ⚰️ 🪦 ⚱️ 🏺 🔮 📿 🧿 🪬 💈 ⚗️ 🔭 🔬 🕳️ 🩹 🩺 🩻 🩼 💊 💉 🩸 🧬 🦠 🧫 🧪 🌡️ 🧹 🪠 🧺 🧻 🚽 🚿 🛁 🪥 🪒 🧴 🧷 🧼 🫧 🧽 🧯 🛒 🎁 🎈 🎏 🎀 🪄 🪅 🎊 🎉 🎎 🏮 🎐 🧧 ✉️ 📩 📨 📧 💌 📥 📤 📦 🏷️ 🪧 📪 📫 📬 📭 📮 📯 📜 📃 📄 📑 🧾 📊 📈 📉 🗒️ 🗓️ 📆 📅 🗑️ 📇 🗃️ 🗳️ 🗄️ 📋 📁 📂 🗂️ 🗞️ 📰 📓 📔 📒 📕 📗 📘 📙 📚 📖 🔖 🧷 🔗 📎 🖇️ 📐 📏 🧮 📌 📍 ✂️ 🖊️ 🖋️ ✒️ 🖌️ 🖍️ 📝 ✏️ 🔍 🔎 🔏 🔐 🔒 🔓
        """)

    private static let symbols = parse("""
        ❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 🩷 🩵 🩶 💔 ❤️‍🔥 ❤️‍🩹 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 ☮️ ✝️ ☪️ 🕉️ ☸️ ✡️ 🔯 🕎 ☯️ ☦️ 🛐 ⛎ ♈ ♉ ♊ ♋ ♌ ♍ ♎ ♏ ♐ ♑ ♒ ♓ 🆔 ⚛️ 🉑 ☢️ ☣️ 📴 📳 🈶 🈚 🈸 🈺 🈷️ ✴️ 🆚 💮 🉐 ㊙️ ㊗️ 🈴 🈵 🈹 🈲 🅰️ 🅱️ 🆎 🆑 🅾️ 🆘 ❌ ⭕ 🛑 ⛔ 📛 🚫 💯 💢 ♨️ 🚷 🚯 🚳 🚱 🔞 📵 🚭 ❗ ❕ ❓ ❔ ‼️ ⁉️ 🔅 🔆 〽️ ⚠️ 🚸 🔱 ⚜️ 🔰 ♻️ ✅ 🈯 💹 ❇️ ✳️ ❎ 🌐 💠 Ⓜ️ 🌀 💤 🏧 🚾 ♿ 🅿️ 🛗 🈳 🈂️ 🛂 🛃 🛄 🛅 🚹 🚺 🚼 ⚧️ 🚻 🚮 🎦 📶 🈁 🔣 ℹ️ 🔤 🔡 🔠 🆖 🆗 🆙 🆒 🆕 🆓 0️⃣ 1️⃣ 2️⃣ 3️⃣ 4️⃣ 5️⃣ 6️⃣ 7️⃣ 8️⃣ 9️⃣ 🔟 🔢 #️⃣ *️⃣ ⏏️ ▶️ ⏸️ ⏯️ ⏹️ ⏺️ ⏭️ ⏮️ ⏩ ⏪ ⏫ ⏬ ◀️ 🔼 🔽 ➡️ ⬅️ ⬆️ ⬇️ ↗️ ↘️ ↙️ ↖️ ↕️ ↔️ ↪️ ↩️ ⤴️ ⤵️ 🔀 🔁 🔂 🔄 🔃 🎵 🎶 ➕ ➖ ➗ ✖️ 🟰 ♾️ 💲 💱 ™️ ©️ ®️ 👁️‍🗨️ 🔚 🔙 🔛 🔝 🔜 ✔️ ☑️ 🔘 🔴 🟠 🟡 🟢 🔵 🟣 ⚫ ⚪ 🟤 🔺 🔻 🔸 🔹 🔶 🔷 🔳 🔲 ▪️ ▫️ ◾ ◽ ◼️ ◻️ 🟥 🟧 🟨 🟩 🟦 🟪 ⬛ ⬜ 🟫 🔈 🔇 🔉 🔊 🔔 🔕 📣 📢 💬 💭 🗯️ ♠️ ♣️ ♥️ ♦️ 🃏 🎴 🀄 🕐 🕑 🕒 🕓 🕔 🕕 🕖 🕗 🕘 🕙 🕚 🕛
        """)

    private static let flags = parse("""
        🏳️ 🏴 🏁 🚩 🏳️‍🌈 🏳️‍⚧️ 🏴‍☠️ 🇺🇳 🇺🇸 🇨🇦 🇲🇽 🇧🇷 🇦🇷 🇨🇱 🇨🇴 🇵🇪 🇬🇧 🇮🇪 🇫🇷 🇩🇪 🇪🇸 🇵🇹 🇮🇹 🇳🇱 🇧🇪 🇨🇭 🇦🇹 🇩🇰 🇸🇪 🇳🇴 🇫🇮 🇮🇸 🇵🇱 🇺🇦 🇨🇿 🇬🇷 🇹🇷 🇷🇴 🇭🇺 🇭🇷 🇷🇸 🇧🇬 🇱🇹 🇱🇻 🇪🇪 🇷🇺 🇬🇪 🇦🇲 🇦🇿 🇮🇱 🇵🇸 🇸🇦 🇦🇪 🇶🇦 🇰🇼 🇯🇴 🇱🇧 🇮🇶 🇮🇷 🇪🇬 🇲🇦 🇩🇿 🇹🇳 🇿🇦 🇳🇬 🇰🇪 🇬🇭 🇪🇹 🇹🇿 🇺🇬 🇸🇳 🇨🇲 🇨🇮 🇦🇺 🇳🇿 🇯🇵 🇰🇷 🇨🇳 🇭🇰 🇹🇼 🇮🇳 🇵🇰 🇧🇩 🇱🇰 🇳🇵 🇧🇹 🇹🇭 🇻🇳 🇸🇬 🇲🇾 🇮🇩 🇵🇭 🇲🇲 🇰🇭 🇱🇦 🇲🇳 🇰🇿 🇺🇿 🇦🇫 🇲🇻 🇫🇯 🇵🇬 🇼🇸 🇹🇴 🇨🇺 🇯🇲 🇩🇴 🇵🇷 🇨🇷 🇵🇦 🇬🇹 🇭🇳 🇳🇮 🇸🇻 🇧🇸 🇧🇧 🇹🇹 🇻🇪 🇪🇨 🇧🇴 🇵🇾 🇺🇾 🇬🇾 🇸🇷
        """)

    static func emojis(for category: NativeEmojiCategory) -> [String] {
        switch category {
        case .recent: frequentlyUsed
        case .smileys: smileys
        case .animals: animals
        case .food: food
        case .activities: activities
        case .travel: travel
        case .objects: objects
        case .symbols: symbols
        case .flags: flags
        }
    }

    /// Unicode already ships a stable name for every scalar, which gives the extension a broad
    /// offline index without telemetry or a copied private Emoji database. A small alias layer
    /// adds the conversational terms people actually use ("love", "laugh", "party", and so on).
    static func search(_ rawQuery: String) -> [String] {
        let query = rawQuery
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if query.isEmpty { return Array(smileys.prefix(12)) }

        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var output: [String] = []
        var seen = Set<String>()

        func append(_ emoji: String) {
            guard seen.insert(emoji).inserted else { return }
            output.append(emoji)
        }

        for (term, emojis) in featuredResults where query == term || query.contains(term) {
            emojis.forEach(append)
        }

        for category in NativeEmojiCategory.allCases where category != .recent {
            for emoji in emojis(for: category) {
                let scalarNames = emoji.unicodeScalars.compactMap { scalar -> String? in
                    switch scalar.value {
                    case 0xfe0e, 0xfe0f, 0x200d: return nil
                    default: return scalar.properties.name?.lowercased()
                    }
                }.joined(separator: " ")
                let searchable = [
                    scalarNames,
                    category.title.lowercased(),
                    aliases[emoji] ?? "",
                ].joined(separator: " ")
                if tokens.allSatisfy(searchable.contains) { append(emoji) }
            }
        }
        return output
    }

    static func toneVariants(for emoji: String) -> [String]? {
        let scalars = Array(emoji.unicodeScalars)
        guard !scalars.contains(where: { (0x1f3fb...0x1f3ff).contains($0.value) }) else {
            return nil
        }

        let eligible = scalars.indices.filter { index in
            guard let name = scalars[index].properties.name?.uppercased() else { return false }
            return toneNameFragments.contains(where: name.contains)
        }
        // Family/couple sequences need more than one independently selected modifier. Presenting
        // a one-person palette for those would create malformed combinations, so leave them alone.
        guard eligible.count == 1, let insertionIndex = eligible.first else { return nil }

        let modifiers = (0x1f3fb...0x1f3ff).compactMap(Unicode.Scalar.init)
        let variants = modifiers.map { modifier -> String in
            var modified = scalars
            modified.insert(modifier, at: insertionIndex + 1)
            return String(String.UnicodeScalarView(modified))
        }
        return [emoji] + variants
    }

    private static let toneNameFragments = [
        "HAND", "FINGER", "THUMB", "FIST", "BICEPS", "EAR", "NOSE", "LEG", "FOOT",
        "PERSON", "MAN", "WOMAN", "BOY", "GIRL", "BABY", "CHILD", "ADULT", "BEARD",
        "PRINCE", "PRINCESS", "DANCER", "RUNNER", "SURFER", "SWIMMER", "POLICE",
        "GUARDSMAN", "DETECTIVE", "CONSTRUCTION WORKER", "SANTA", "FATHER CHRISTMAS",
        "MOTHER CHRISTMAS", "ANGEL", "MAGE", "FAIRY", "VAMPIRE", "MERPERSON", "ELF",
        "MASSAGE", "HAIRCUT", "WALKING", "STANDING", "KNEELING", "ROWBOAT", "BICYCLIST",
        "CARTWHEELING", "WRESTLERS", "WATER POLO", "HANDBALL", "JUGGLING", "SELFIE",
        "NAIL POLISH", "BOWING", "BATH", "HORSE RACING",
    ]

    private static let featuredResults: [String: [String]] = [
        "heart": ["❤️", "😘", "😍", "🥰", "💕", "💖", "💗", "💓", "💘", "💝"],
        "love": ["❤️", "🥰", "😍", "😘", "🫶", "💕", "💞", "💖"],
        "laugh": ["😂", "🤣", "😹", "😆", "😅"],
        "cry": ["😭", "😢", "🥹", "😿"],
        "happy": ["😀", "😃", "😄", "😁", "😊", "☺️"],
        "sad": ["😢", "😭", "😞", "😔", "🙁", "☹️"],
        "party": ["🥳", "🎉", "🎊", "🪩", "🎈"],
        "fire": ["🔥", "❤️‍🔥", "🚒", "🧯"],
        "yes": ["✅", "👍", "👌", "🆗"],
        "no": ["❌", "👎", "🚫", "⛔"],
    ]

    private static let aliases: [String: String] = [
        "😂": "laugh laughing tears joy funny lol",
        "🤣": "laugh laughing rolling funny lol",
        "🥹": "tears grateful touched proud cry",
        "😊": "happy smile blush",
        "😍": "love heart eyes crush",
        "🥰": "love hearts affection",
        "😘": "love heart kiss",
        "🤭": "oops giggle laugh secret",
        "🫶": "love heart hands support",
        "🙏": "please pray thanks grateful high five",
        "👍": "yes good approve like",
        "👎": "no bad disapprove dislike",
        "🔥": "fire hot lit excellent",
        "✨": "sparkle stars magic clean",
        "🎉": "party celebrate congratulations",
        "💯": "hundred perfect agree",
        "👀": "eyes look watching",
        "💀": "dead skull dying laugh",
        "✅": "yes check done complete",
        "❤️": "heart love red",
        "💕": "heart love two",
        "💖": "heart love sparkle",
        "🤍": "heart love white",
        "💔": "heart love broken sad",
        "🐶": "dog puppy pet",
        "🐱": "cat kitten pet",
        "🐵": "monkey animal",
        "🍔": "burger hamburger food",
        "🍟": "fries chips food",
        "🍕": "pizza food",
        "☕": "coffee hot drink cafe",
        "⚽": "soccer football sport",
        "🏈": "football sport",
        "🚗": "car auto vehicle travel",
        "✈️": "plane airplane flight travel",
        "💡": "idea light bulb",
        "📱": "phone mobile iphone",
        "🎁": "gift present birthday",
    ]

    private static func parse(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
