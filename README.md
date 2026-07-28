# Private Music 2.2

Clean SwiftUI sources for a private music player inspired by the inspected IPA.
The project is independent from the patched `Private Music [1.1].ipa`.

## Implemented

- dark blue/violet Private Music design;
- library, recommendations, search and profile tabs;
- queue-based `AVPlayer`;
- queue editor, play-next, shuffle, repeat and sleep timer;
- background audio;
- Lock Screen / Control Center metadata;
- play, pause, toggle, next, previous and seek remote commands;
- artwork loading with stale-result protection;
- Keychain session storage;
- VKpyMusic token and matching User-Agent import;
- ephemeral cookie-free networking;
- no-tracking Privacy Manifest;
- VK API adapter for profile, tracks, recommendations, search and playlists;
- adding tracks from search and removing tracks from the library;
- playlist creation, editing, deletion and track management;
- artist screens, VK lyrics and direct-file sharing;
- four themes, appearance modes and native iOS 26 Liquid Glass;
- five-band real-time DSP equalizer based on an AVPlayer audio tap;
- Telegram group and VPN buttons;
- unit test for VK track decoding;
- unsigned cloud build workflow.

## VKpyMusic local login

Private Music itself does not ask for a VK password or OTP and contains no
copied `client_secret`. On Windows, run `VKpyMusic Login.cmd`. The helper creates
an isolated Python environment, installs the pinned `vkpymusic==4.0.2` package
and asks for the account credentials locally. Copy the resulting
`token_for_audio` and `user_agent` values into the connection screen.

The helper does not save the password. The imported token and User-Agent are
validated through `users.get` and stored in the iOS Keychain. VKpyMusic uses an
unofficial mobile authorization flow; VK may change or block it at any time.
Use only your own account and never share the resulting token.

## Generate the Xcode project

On macOS:

```bash
brew install xcodegen
cd PrivateMusic2
bash ./scripts/bootstrap.sh
open PrivateMusic.xcodeproj
```

Select a Development Team in Signing & Capabilities. A certificate is not
needed for simulator builds, but is required to install the app on an iPhone.

## Build in the cloud without a Mac

The included GitHub Actions workflow runs on a macOS runner, compiles the iOS
Simulator target, builds the arm64 iPhone target and packages
`PrivateMusic-2.2.0-unsigned.ipa`. Push the contents of this directory to a GitHub
repository and run the `Build unsigned IPA` workflow.

Download the `PrivateMusic-2.2.0-unsigned` workflow artifact when the job
finishes. The IPA still requires signing before installation on an iPhone.

## Local structural validation

On Windows, Linux or macOS:

```bash
python scripts/validate_project.py
```

## Current limitations

- VKpyMusic login runs locally on Windows rather than inside the iOS app.
- Private VK music methods may reject ordinary official tokens.
- Playlist cover upload and following public playlists are not wired yet.
- VK lyrics require `lyrics_id`; file sharing requires a direct non-HLS stream.
- A real-device test is required for background audio and system Now Playing.

See [FEATURE_PARITY.md](FEATURE_PARITY.md) for a comparison with the legacy IPA.

Developer: **decoder-dev**.
