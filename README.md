<p align="center">
  <img src="assets/logo.png" width="120" alt="Ekko" />
</p>

<h1 align="center">Ekko for iOS</h1>
<p align="center"><i>Say it like no one is listening.</i></p>

The iPhone half of [Ekko](https://github.com/useekko): post-quantum encrypted messages
inside the apps you already use. No new messenger, and nobody to talk into switching.

**The code is not here yet.** It is being built now, in private, and this repo is where it
lands. What follows is what is being built, so you know what is coming.

## Three pieces

**The app.** Your identity lives here. One key pair, generated on the phone, and it does
not leave. A 24-word recovery phrase, your contacts, your @handle if you want one, and
safety numbers so you can verify a person is who they say they are.

**The keyboard.** This is the reason the iOS build exists. A phone gives no way to reach
inside Instagram's or WhatsApp's *native* app, so Ekko ships a keyboard instead. It has its
own keys. What you type goes into Ekko, gets sealed there, and ciphertext is what lands in
the messenger's text field. Turn the lock off and it types straight through like any other
keyboard, so it does not have to be swapped out for ordinary chats.

**The Safari extension.** The browser extension, running in Safari on iPhone and on Mac.

## One identity, both ends

The same 24 words produce the same identity on the phone and in the browser extension.
Restore your phrase on a new device and your fingerprint, your @handle, and everyone who
can reach you are unchanged. A message sealed in Chrome opens on the phone, and the reverse.

## Status

In development. Not shipped, no TestFlight yet. The browser extension is in private alpha
and early access goes through the site.

## Links

- Org: [github.com/useekko](https://github.com/useekko)
- Core repo: [useekko/ekko-core](https://github.com/useekko/ekko-core)
- Site: [useekko.app](https://useekko.app)
- X: [@useekko](https://x.com/useekko)
- Discord: [discord.gg/cQytJjVdxu](https://discord.gg/cQytJjVdxu)
- Contact: [kirill@useekko.app](mailto:kirill@useekko.app)

---

This repo fills in as things open up.
