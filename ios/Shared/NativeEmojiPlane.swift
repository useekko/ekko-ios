import SwiftUI

/// Clean-room Emoji surface shared by KeyboardLab and the shipping extension.
///
/// Apple exposes Emoji as a separate public input mode, but an extension cannot jump directly to
/// that mode—the only public system action is "advance to next keyboard." Keeping Emoji in Ekko
/// makes the result deterministic while preserving the system globe below the extension.
struct NativeEmojiPlaneView: View {
    @Binding var plane: NativeKeyboardPlane

    let onText: (String) -> Void
    let onBackspace: () -> Void

    @AppStorage("app.useekko.keyboard.recent-emojis") private var storedRecents = ""
    @State private var category = NativeEmojiCategory.recent

    var body: some View {
        VStack(spacing: 0) {
            categoryHeader
            emojiGrid
            categoryRail
        }
        .frame(height: NativeKeyboardMetrics.planeHeight)
        .background(Ink.keyBacking)
    }

    private var categoryHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: category.icon)
                .font(.system(size: 12, weight: .semibold))
            Text(category.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.7)
            Spacer(minLength: 0)
            Text("Swipe to browse")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Ink.keyboardMuted.opacity(0.72))
        }
        .foregroundStyle(Ink.keyboardMuted)
        .padding(.horizontal, 12)
        .frame(height: 29)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category.title)
    }

    private var emojiGrid: some View {
        let rows = Array(
            repeating: GridItem(.fixed(36), spacing: 0, alignment: .center),
            count: 4
        )

        return ScrollView(.horizontal) {
            LazyHGrid(rows: rows, alignment: .center, spacing: 0) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, emoji in
                    NativeEmojiCell(emoji: emoji) { insert(emoji) }
                }
            }
            .padding(.horizontal, 4)
        }
        .id(category)
        .scrollIndicators(.hidden)
        .frame(height: 144)
        .contentMargins(.horizontal, 0, for: .scrollContent)
    }

    private var categoryRail: some View {
        HStack(spacing: 0) {
            Button {
                plane = .letters
            } label: {
                Text("ABC")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(width: 53)
            .accessibilityLabel("Letters")
            .accessibilityIdentifier("emoji-letters")

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(NativeEmojiCategory.allCases) { item in
                        Button {
                            withAnimation(.easeOut(duration: 0.14)) { category = item }
                        } label: {
                            Image(systemName: item.icon)
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(
                                    category == item ? Ink.keyboardInk : Ink.keyboardMuted
                                )
                                .frame(width: 37, height: 37)
                                .background {
                                    if category == item {
                                        Circle().fill(Ink.keyboardInk.opacity(0.12))
                                    }
                                }
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityIdentifier("emoji-category-\(item.rawValue)")
                    }
                }
            }
            .scrollIndicators(.hidden)

            NativeEmojiDeleteButton(action: onBackspace)
                .frame(width: 53)
        }
        .frame(height: 52)
        .overlay(alignment: .top) {
            Rectangle().fill(Ink.keyboardLine).frame(height: 0.5)
        }
    }

    private var emojis: [String] {
        if category == .recent {
            let saved = storedRecents
                .split(separator: "\u{001F}")
                .map(String.init)
                .filter { !$0.isEmpty }
            return saved + NativeEmojiCatalog.frequentlyUsed.filter { !saved.contains($0) }
        }
        return NativeEmojiCatalog.emojis(for: category)
    }

    private func insert(_ emoji: String) {
        onText(emoji)
        var recent = storedRecents
            .split(separator: "\u{001F}")
            .map(String.init)
        recent.removeAll { $0 == emoji }
        recent.insert(emoji, at: 0)
        storedRecents = recent.prefix(40).joined(separator: "\u{001F}")
    }
}

private struct NativeEmojiCell: View {
    let emoji: String
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Text(emoji)
            .font(.system(size: 29))
            .frame(width: 43, height: 36)
            .background(
                pressed ? Ink.key.opacity(0.82) : .clear,
                in: .rect(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(pressed ? 1.16 : 1)
            .zIndex(pressed ? 2 : 0)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { value in
                        let activate = CGRect(x: -8, y: -8, width: 59, height: 52)
                            .contains(value.location)
                        pressed = false
                        if activate { action() }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(emoji)
            .accessibilityIdentifier("emoji-\(emoji)")
            .accessibilityAddTraits([.isKeyboardKey, .isButton])
            .accessibilityAction { action() }
    }
}

private struct NativeEmojiDeleteButton: View {
    let action: () -> Void

    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(Ink.keyboardInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                pressed ? Ink.keyPressed : Ink.keyModifier,
                in: .rect(cornerRadius: 7, style: .continuous)
            )
            .padding(.horizontal, 5)
            .padding(.vertical, 7)
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

    private static func parse(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
