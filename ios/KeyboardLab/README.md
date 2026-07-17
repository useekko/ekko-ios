# KeyboardLab

A standalone clean-room harness for matching Ekko's production key plane to the current native
iPhone keyboard. It switches one `UITextView` between Apple and `NativeKeyPlaneView`, which is the
same source file compiled into `EkkoKeyboard`.

```bash
cd ios/KeyboardLab
xcodegen generate
xcodebuild test -scheme KeyboardLab \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

Use a clean simulator whose keyboard list contains only English and Emoji. Each light/dark run
captures letters, `123`, and `#+=` and retains full screenshots, normalized plane crops,
side-by-sides, absolute differences, and JSON reports. A connected-component analyzer measures the
visible caps; the gate requires <= 1pt maximum / <= 0.2pt mean geometry delta, <= 0.34pt maximum
touch-target delta, and exact primary/backing colors. The interaction test also drives one-shot
Shift, double-tap Caps Lock, every plane transition, Space, typing, tap Delete, and held-Delete
repeat.

This is clean-room observation of public rendered output. The lab does not inspect, link, or call
private Apple keyboard implementation details. It compiles `../Shared/NativeKeyPlane.swift`
directly, so a passing replica is the renderer shipped by `EkkoKeyboard`, not a lookalike test copy.
