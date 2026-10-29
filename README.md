<div align="center">

<img src="https://raw.githubusercontent.com/wiroai/Swift-Realtime/main/.github/assets/wiro-logo.png" alt="Wiro AI" width="240">

# Wiro Realtime for Swift: Voice AI Example for iOS

Realtime voice AI for iOS in Swift and SwiftUI: live conversation, speech-to-text and text-to-speech with the Wiro AI API.

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-111111?style=for-the-badge&color=111111&logo=swift&logoColor=white)](https://swift.org) [![iOS 26.0+](https://img.shields.io/badge/iOS-26.0%2B-111111?style=for-the-badge&color=111111&logo=apple&logoColor=white)](#requirements) [![CI](https://img.shields.io/github/actions/workflow/status/wiroai/Swift-Realtime/tests.yml?branch=main&style=for-the-badge&color=111111&label=CI&logo=githubactions&logoColor=white)](https://github.com/wiroai/Swift-Realtime/actions/workflows/tests.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-111111?style=for-the-badge&color=111111)](LICENSE)

[Website](https://wiro.ai) · [Models](https://wiro.ai/models) · [Docs](https://wiro.ai/docs/realtime-voice-conversation) · [Dashboard](https://wiro.ai/panel)

</div>

Wiro Realtime for Swift is the official open-source example for
building realtime voice AI into an iOS app with Swift, SwiftUI and the
Wiro AI API. Its three tabs stream audio over WebSocket for a live
speech-to-speech conversation with barge-in, live speech-to-text from
the microphone, and text-to-speech playback. The auth, networking,
realtime and audio layers have no UI dependency, so you can lift them
into your own app.

<p align="center">
  <img src="docs/images/conversation.png" alt="Conversation tab of the SwiftUI app with the Marin voice, settings and a Start button" width="220">
  <img src="docs/images/transcription.png" alt="Transcription tab of the SwiftUI app with the Balanced accuracy setting and a Start button" width="220">
  <img src="docs/images/speech.png" alt="Speech tab of the SwiftUI app with a text-to-speech prompt, the MOSS TTS Realtime model and a Play button" width="220">
</p>

## What's inside

Three realtime audio flows, each a tab in the app, each backed by a
live Wiro AI model over one WebSocket protocol:

| Flow | Model | What it does |
| --- | --- | --- |
| Conversation | [`openai/gpt-realtime-mini`](https://wiro.ai/models/openai/gpt-realtime-mini) | Full-duplex voice chat with barge-in |
| Transcription | [`mistralai/voxtral-mini-4b-realtime-2602`](https://wiro.ai/models/mistralai/voxtral-mini-4b-realtime-2602) | Live speech-to-text as you talk |
| Speech | [`openmoss/moss-tts-realtime`](https://wiro.ai/models/openmoss/moss-tts-realtime) or [`openbmb/voxcpm2`](https://wiro.ai/models/openbmb/voxcpm2) | Streaming text-to-speech playback |

The chrome is system SwiftUI: `TabView`, `NavigationStack`, toolbar
items, `Menu`, `Form`, `List`. Liquid Glass comes from iOS 26, light
and dark follow the system, and there is no custom orb, wave, or tab
bar. The screens carry no instructions: Start is the one prominent
button, and the stage shows what is happening.

## Features

- Live speech-to-speech conversation with voice activity detection,
  barge-in, and a noise gate
- Realtime microphone transcription with streaming partial results
- Streaming text-to-speech with bounded PCM playback
- One `AVAudioEngine` graph for capture and playback, so the OS echo
  canceller (AEC) actually works
- Signed REST Run requests and the full Wiro AI realtime WebSocket
  protocol
- Bounded capture/playback queues, safe PCM overflow shedding, audio
  route and interruption handling
- Cross-feature guard so two tabs never hold the microphone at once
- Automatic reconnect to the same task on socket drops, with a
  bounded restart budget
- Session lifecycle covered by XCTest fakes, so no device is needed
  to verify the plumbing

## Requirements

- Xcode 26 or later
- A **physical** iPhone on iOS 26 or later (the simulator microphone
  is not a usable voice path)
- An Apple Developer team for signing on that iPhone: set
  `DEVELOPMENT_TEAM` in `Configs/Secrets.xcconfig` (see below), since
  the project file ships without one
- A [Wiro AI project and API key](https://wiro.ai/panel/project/new)

No CocoaPods and no Swift package dependencies. The project is one
folder-synced app target plus its unit-test target.

## Run

Copy the credential template and set the key:

```sh
cp Configs/Secrets.xcconfig.example Configs/Secrets.xcconfig
```

Edit `Configs/Secrets.xcconfig`:

```
WIRO_API_KEY = YOUR_API_KEY
WIRO_API_SECRET =
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

`WIRO_API_SECRET` is only for signature-based Wiro AI projects. Leave
it empty for API-key-only projects. `DEVELOPMENT_TEAM` is the
ten-character id from your Apple Developer account; the simulator
builds without it. The secrets file is gitignored.

Then:

```sh
open SwiftRealtime.xcodeproj
```

Select the **SwiftRealtime** scheme, pick a physical iPhone, and run.

Alternatively, leave the xcconfig empty and set `WIRO_API_KEY` (and
optionally `WIRO_API_SECRET`) on the scheme's environment. Scheme
env wins over the compiled Info.plist values.

Launch fails fast when `WIRO_API_KEY` is missing.

> **Credentials warning:** values from `.xcconfig` are compiled into
> the binary and can be read out of any build you distribute. This
> is fine for a developer running the example on their own phone. It
> is not fine for an app in the App Store: see
> [Shipping to users](#shipping-to-users) before you do that.

## Shipping to users

The API key is only needed for one call: `POST /Run`, which creates
the task and returns a `socketaccesstoken`. Everything after that
(the WebSocket subscribe, the audio frames, the session end) is
authenticated by that per-task token alone. So the key never has to
leave your server.

The seam is the `WiroApiClient` protocol
([`SwiftRealtime/Networking/WiroApiClient.swift`](SwiftRealtime/Networking/WiroApiClient.swift)).
Implement it against your own backend, which holds the key, calls
`/Run` (and `/Task/Kill` for `terminateTaskBestEffort`), and hands
back the task id and token:

```swift
final class BrokeredWiroApiClient: WiroApiClient, @unchecked Sendable {
    func createCancellation() -> WiroRequestCancellation { .init() }

    func runModel(
        model: ModelDefinition,
        parameters: [String: Any],
        cancellation: WiroRequestCancellation?,
    ) async throws -> WiroRunResult {
        // POST to your server; it calls Wiro with the key and returns
        // { "taskId": ..., "taskToken": ... }.
    }

    func terminateTaskBestEffort(taskId: String, taskToken: String) async {
        // POST to your server; it calls /Task/Kill.
    }
}
```

Then build `RealtimeSessionDependencies` with it instead of the
credential-based convenience initializer:

```swift
RealtimeSessionDependencies(
    httpClient: URLSessionWiroHttpClient(),
    apiClient: BrokeredWiroApiClient(),
    readyTimeout: .seconds(15),
)
```

Nothing under `Realtime/` or `Audio/` changes: the socket client
only ever sees the task token. Your server decides who may start a
billed task, how many, and for how long, which is the control you
want over a metered resource anyway.

## Make it yours

[`SwiftRealtime/App/Config/ConversationConfig.swift`](SwiftRealtime/App/Config/ConversationConfig.swift)
holds the persona, the voice, and the model.
Editing that one file is the whole of turning this example into a
product.

```swift
static let persona = "...who the assistant is..."
static let voice = "marin"
```

Common changes:

- **Give the assistant a job**: rewrite `persona`.
- **Change the voice**: set `voice` to any option the model catalog
  lists.
- **Tune the engineering parameters**: `parameters` overrides the
  catalog defaults for turn detection, audio formats, and rates.
- **Ship only the conversation**: delete
  `SwiftRealtime/Views/Transcription/`,
  `SwiftRealtime/Views/Speech/`,
  `SwiftRealtime/Services/Transcription/`, and
  `SwiftRealtime/Services/Speech/` (plus their `Tests/` mirrors),
  then remove the two `Tab`s from
  `SwiftRealtime/Views/Home/RealtimeHomeView.swift`. Shared layers
  under `Models/`, `Networking/`, `Auth/`, `Realtime/`, and
  `Audio/` are untouched.

## How a conversation runs

```text
REST:      https://api.wiro.ai/v1
WebSocket: wss://socket.wiro.ai/v1
Run:       POST /Run/{owner}/{model}
```

1. `POST /Run/{owner}/{model}` returns a task id and a task token
   (`socketaccesstoken`).
2. A WebSocket opens and subscribes with
   `{ "type": "task_info", "tasktoken": "..." }`.
3. After `task_stream_ready`, 20 ms PCM chunks stream up as
   `UTF8(tasktoken + "|") + pcm_bytes`; audio frames come back in the
   same shape. Transcripts arrive as `task_output` messages prefixed
   `TRANSCRIPT_USER:` / `TRANSCRIPT_AI:`; `task_stream_end` marks the
   end of each assistant turn; `task_cost` reports `turnCost` and
   `cumulativeCost` as the conversation goes.
4. The app sends `task_session_end` on leave and gives the server a
   bounded window to answer with `task_postprocess_end` before it
   closes the socket. `task_end` alone only means the model process
   exited. A client that disconnects without `task_session_end` is
   cleaned up by the server, and so is a task whose wallet runs dry.

Audio is signed 16-bit PCM, 24 kHz, mono, little-endian on both
sides. The Wiro AI browser example sends 200 ms frames; this app
sends 20 ms frames because barge-in latency is bounded by the frame
size, and the server accepts either.

Authentication is `x-api-key` alone, or `x-api-key` + `x-nonce` +
`x-signature` where the signature is
`HMAC-SHA256(key = API_KEY, message = API_SECRET + NONCE)`.

## Project layout

```text
SwiftRealtime/
  App/            entry, AppColors, ConversationConfig
  Models/         catalog, parameters, run result
  Networking/     HTTP, endpoints, Run launcher
  Auth/           credentials, nonce, headers
  Realtime/       socket, session, framing
  Audio/          PCM, engine, session
  Services/       Conversation / Transcription / Speech
  Views/          Home / Conversation / Transcription / Speech / Shared
Tests/            mirrors the app; Support/ holds fakes
Configs/
  Secrets.xcconfig.example   credential template (copy locally)
```

`Models/`, `Networking/`, `Auth/`, `Realtime/`, and `Audio/` have
no dependency on any view or screen service and cover the whole
Wiro AI integration, so they are the part worth lifting into your
own app.

## Tests

```sh
WIRO_API_KEY=test xcodebuild test \
  -scheme SwiftRealtime \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Tests mirror `SwiftRealtime/` and ship fakes for audio, network, and
the socket, so the entire session lifecycle runs without a device.
Time-dependent code takes a `RealtimeClock`; tests drive a
`TestClock` by hand, so no test waits on the wall.

CI (`.github/workflows/tests.yml`) runs the suite on an iOS 26
simulator plus `swiftformat --lint`, `swiftlint --strict`, and an
80-column check, on pushes to `main` and on pull requests.

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull
request. To report a security problem, follow
[`SECURITY.md`](SECURITY.md) instead of opening a public issue.

## Documentation

- [Realtime voice guide](https://wiro.ai/docs/realtime-voice-conversation)
- [Wiro AI documentation](https://wiro.ai/docs)
- [Available models](https://wiro.ai/models)
- Same example on other platforms:
  [Kotlin](https://github.com/wiroai/Kotlin-Realtime) ·
  [Flutter](https://github.com/wiroai/Dart-Realtime) ·
  [React Native](https://github.com/wiroai/ReactNative-Realtime)
- [Swift-QuickStart](https://github.com/wiroai/Swift-QuickStart):
  WiroKit, the Wiro AI SDK for iOS

## More from Wiro AI

| Repository | What it is |
| --- | --- |
| [Wiro-MCP](https://github.com/wiroai/Wiro-MCP) | Official MCP server for Wiro AI, [`@wiro-ai/wiro-mcp` on npm](https://www.npmjs.com/package/@wiro-ai/wiro-mcp) |
| [Wiro-Plugin](https://github.com/wiroai/Wiro-Plugin) | Wiro AI plugin for Cursor, Claude Code, Gemini CLI and Devin |
| [Swift-QuickStart](https://github.com/wiroai/Swift-QuickStart) | WiroKit, the Wiro AI SDK for iOS |
| [Kotlin-QuickStart](https://github.com/wiroai/Kotlin-QuickStart) | WiroKit, the Wiro AI SDK for Android |
| [Dart-QuickStart](https://github.com/wiroai/Dart-QuickStart) | Wiro AI SDK for Dart and Flutter, [`wiro` on pub.dev](https://pub.dev/packages/wiro) |
| [ReactNative-QuickStart](https://github.com/wiroai/ReactNative-QuickStart) | Wiro AI SDK for React Native and Expo, [`@wiro-ai/wiro-react-native` on npm](https://www.npmjs.com/package/@wiro-ai/wiro-react-native) |
| [Kotlin-Realtime](https://github.com/wiroai/Kotlin-Realtime) | Realtime voice AI example for Android |
| [Dart-Realtime](https://github.com/wiroai/Dart-Realtime) | Realtime voice AI example for Flutter |
| [ReactNative-Realtime](https://github.com/wiroai/ReactNative-Realtime) | Realtime voice AI example for React Native |
| [n8n-nodes-wiroai](https://github.com/wiroai/n8n-nodes-wiroai) | Wiro AI nodes for n8n, [`@wiro-ai/n8n-nodes-wiroai` on npm](https://www.npmjs.com/package/@wiro-ai/n8n-nodes-wiroai) |
| [Wiro-Docs](https://github.com/wiroai/Wiro-Docs) | Source of the Wiro AI API docs |

[Website](https://wiro.ai) · [Models](https://wiro.ai/models) · [Docs](https://wiro.ai/docs) · [X](https://x.com/wiroai)

## License

[MIT](LICENSE)

---

<div align="center">

<img src="https://wiro.ai/images/koala/accent-heavy-koala.png" alt="Wiro AI koala mascot" width="80" />

**Built by the Wiro AI team**

[wiro.ai](https://wiro.ai) · [GitHub @wiroai](https://github.com/wiroai)

</div>
