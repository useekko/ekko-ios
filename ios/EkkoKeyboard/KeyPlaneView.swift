import SwiftUI

/// Production adapter around the clean-room plane shared with KeyboardLab. Ekko's state machine
/// stays independent of the renderer, while every measured geometry/rendering change lands here
/// automatically because both targets compile `NativeKeyPlaneView`.
struct KeyPlaneView: View {
    @Bindable var model: KeyboardModel
    var showsGlobe: Bool

    var body: some View {
        NativeKeyPlaneView(
            plane: plane,
            shifted: $model.shifted,
            capsLock: $model.capsLock,
            showsGlobe: showsGlobe,
            showsEmoji: true,
            onText: { model.tap($0) },
            onBackspace: { model.backspace() },
            onNextKeyboard: { model.host?.nextKeyboard() }
        )
    }

    private var plane: Binding<NativeKeyboardPlane> {
        Binding(
            get: {
                switch model.plane {
                case .letters: .letters
                case .numbers: .numbers
                case .symbols: .symbols
                case .emoji: .emoji
                }
            },
            set: { value in
                switch value {
                case .letters: model.plane = .letters
                case .numbers: model.plane = .numbers
                case .symbols: model.plane = .symbols
                case .emoji: model.plane = .emoji
                }
            }
        )
    }
}
