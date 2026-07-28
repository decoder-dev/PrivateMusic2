# Private Music 2.0

Clean SwiftUI sources for a private music player inspired by the inspected IPA.
The project is independent from the patched `Private Music [1.1].ipa`.

## Implemented

- dark blue/violet Private Music design;
- library, recommendations, search and profile tabs;
- queue-based `AVPlayer`;
- background audio;
- Lock Screen / Control Center metadata;
- play, pause, toggle, next, previous and seek remote commands;
- artwork loading with stale-result protection;
- Keychain session storage;
- ephemeral cookie-free networking;
- no-tracking Privacy Manifest;
- VK API adapter for profile, tracks, recommendations, search and playlists;
- adding tracks from search and removing tracks from the library;
- Telegram group and VPN buttons;
- unit test for VK track decoding;
- unsigned cloud build workflow.

## Safe authentication model

The project does not ask for a VK password or OTP and does not inject JavaScript
into CAPTCHA pages. It also contains no copied `client_secret`.

There is no demo mode or bundled demo audio in the release. The connection
screen validates an existing access token through `users.get` before storing it
in Keychain. Availability of `audio.*` methods depends on VK permissions;
registering a new application and integrating the official
[VK SDK](https://github.com/VKCOM/VKSDK-iOS) is the production path.

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
`PrivateMusic-2.0.0-unsigned.ipa`. Push the contents of this directory to a GitHub
repository and run the `Build unsigned IPA` workflow.

Download the `PrivateMusic-2.0.0-unsigned` workflow artifact when the job
finishes. The IPA still requires signing before installation on an iPhone.

## Local structural validation

On Windows, Linux or macOS:

```bash
python scripts/validate_project.py
```

## Current limitations

- Official VK ID authorization is not wired until a new VK application is
  registered.
- Private VK music methods may reject ordinary official tokens.
- Playlist creation/editing and lyrics require additional VK API permissions.
- A real-device test is required for background audio and system Now Playing.
