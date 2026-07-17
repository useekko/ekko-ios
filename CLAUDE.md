# Ekko iOS — session bootstrap

The iOS app + custom keyboard + Safari extension (`ios/`), over one shared Swift port of the
TypeScript core (`ios/EkkoCore`, local SPM package). The extension/protocol/server half lives in
github.com/useekko/ekko-core. Wire format: new output `EKK1*`, readers keep `RSN1*` compatibility
(`docs/PROTOCOL.md` — internal KDF labels are frozen on purpose).

**Read `docs/IOS.md` before anything else; `docs/DESIGN.md` before touching UI.**

## The invariants — break these and the product is a lie

- **Private keys never leave the device.** An account can never hold a key; the 24 words re-derive
  it. If a change puts a key, passphrase, or plaintext anywhere but the device, it is wrong.
- **Plaintext never enters the host app.** The keyboard seals in its own buffer; the test named
  "locked keystrokes never reach the host app's text field" is the one that matters. Reading
  happens in the keyboard's own opaque reader, never by inserting plaintext into the host.
- **`ios/EkkoCore` and ekko-core's `src/core` must agree byte for byte.** The committed
  `vectors.json` is generated from the TypeScript core; a crypto change updates both repos.
- **The keyboard makes no network requests.** `NoNetworkTests` greps everything it links.
  Keep it true or change the copy that promises it.
- **Mono is machine output only** (ciphertext, safety numbers, the 24 words) — never a label.
- **No overclaiming in copy.** Say what is true, including what an attacker can still reach
  (`docs/THREAT_MODEL.md`).

## Gotchas that have each cost a day

- `CODE_SIGNING_ALLOWED: NO` silently kills the App Group — the app falls back to a temp dir and
  the keyboard can never see the vault. Nothing errors. It must stay `YES`.
- Edit `ios/project.yml`, never the `.pbxproj`. Regenerate with `cd ios && xcodegen generate`.
- `simctl uninstall` leaves the App Group vault behind — `scripts/ios-reset-sim.sh` is the real
  clean slate, and the onboarding UI tests need it.
- iOS 26 floor exists because CryptoKit's ML-KEM landed there; `apple/swift-crypto` is the
  escape hatch if the floor ever has to drop.

## Working here

- `cd ios/EkkoCore && swift test` green before any PR; keyboard/UI suites from Xcode if touched.
- Branch `feat/*`, open a PR, no direct pushes to `main`.
