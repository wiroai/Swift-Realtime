# Contributing

Thanks for taking the time. This is a small, opinionated example app;
the bar for a change is that it keeps the example small and opinionated.

## Before you start

- Read [`AGENTS.md`](AGENTS.md). It is the architecture document: the
  layer rules, the chrome rules, and the reasons behind the session
  lifecycle. Pull requests that contradict it will be asked to change.
- Open an issue first for anything that adds a screen, a dependency,
  or a new layer. Bug fixes and test improvements can go straight to a
  pull request.

## Setup

```sh
cp Configs/Secrets.xcconfig.example Configs/Secrets.xcconfig
open SwiftRealtime.xcodeproj
```

The test suite does not talk to Wiro; any non-empty `WIRO_API_KEY`
satisfies the launch check. A physical iPhone on iOS 26 is needed only
to hear audio.

## Running the checks

```sh
WIRO_API_KEY=test xcodebuild test \
  -scheme SwiftRealtime \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

swiftformat SwiftRealtime Tests --lint
swiftlint lint --strict
```

CI runs the same three commands plus an 80-column check, with the
SwiftFormat and SwiftLint versions pinned in
`.github/workflows/tests.yml`. Install the tools with
`brew install swiftformat swiftlint`; a newer SwiftFormat can flag
code that the pinned one accepts.

## What a good change looks like

- Root layers (`Models/`, `Networking/`, `Auth/`, `Realtime/`,
  `Audio/`) never import a view or a screen service. Services never
  touch view state. Views never import each other.
- Anything that waits on time takes a `RealtimeClock` and is tested
  with `TestClock`, not with `Task.sleep` in the test.
- Shared mutable state sits behind `OSAllocatedUnfairLock`; a type
  marked `@unchecked Sendable` says in its doc comment which threads
  reach it and why the lock is enough.
- Comments explain why, never what. No comment restates the line
  below it.
- 80 columns, trailing commas, system `Font` and system padding. No
  spacing / radius / shadow tokens for chrome.
- Tests live in `Tests/` mirroring `SwiftRealtime/`. Reuse the fakes
  under each `Support/` folder before writing a new one.

## Commit messages

One change per commit, imperative subject under 72 characters, and a
body that says why when the diff does not.

## Reporting a problem

Include the iOS version, the device, the model slug from
`ConversationConfig`, and the last few protocol events if you have
them. A recording of what you heard is worth more than a paragraph
about it.
