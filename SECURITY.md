# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Email
[support@wiro.ai](mailto:support@wiro.ai) with "Security" in the
subject, or use **Security → Report a vulnerability** on
[this repository](https://github.com/wiroai/Swift-Realtime/security/advisories/new).

Include the platform, the steps to reproduce, and what an attacker
gains. You will get an acknowledgement within a few days and a fix
or a written decision before anything is disclosed.

## Scope

This repository is an example client. It covers the Swift code
under `SwiftRealtime/`: request signing, the WebSocket session, PCM
framing, the AVAudioEngine graph, and the screens.

Problems with the Wiro platform itself — the REST API, the realtime
socket, the models — belong to [Wiro](https://wiro.ai), not to this
repository.

## Credentials

`WIRO_API_KEY` and `WIRO_API_SECRET` are read from
`Configs/Secrets.xcconfig` (or the scheme's environment) and
compiled into the app's Info.plist. That is fine for a phone in
your hand and wrong for a store build: anyone with the IPA can read
the key out. A shipped app should obtain credentials from a backend
you control, or use a short-lived credential flow — the README's
"Shipping to users" section covers this. Never commit
`Secrets.xcconfig`; it is gitignored for that reason.

Task tokens are per-session and expire with the task. The code
keeps them out of logs; a change that prints one is a bug.
