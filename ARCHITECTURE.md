# Architecture

Private Music 2.0 is a clean SwiftUI application, not a decompilation of the
original binary.

## Layers

- `App` creates a single dependency container.
- `Core` owns configuration, HTTPS transport and Keychain access.
- `Models` contains immutable `Sendable` domain values.
- `Services` isolates VK-specific response formats behind `MusicService`.
- `LRCLyricsService` provides a cookie-free lyrics fallback.
- `VKAudioURLResolver` restores protected stream URLs locally for the
  authenticated account identifier.
- `Session` owns the current access token and profile.
- `Player` owns `AVPlayer`, background audio, Now Playing and remote commands.
- `Features` contains SwiftUI screens and view models.

## Security decisions

- No password, OTP or CAPTCHA interception.
- No embedded `client_secret`.
- Phone/password/OTP fields stay inside a non-persistent VK `WKWebView`.
- Web navigation is restricted to HTTPS pages owned by `vk.ru` or `vk.com`.
- VK cookies are exchanged directly with `login.vk.ru`. The temporary WebKit
  store is wiped after success or cancellation; the minimum refresh session is
  retained only in the device-only Keychain so short-lived tokens can renew.
- Session token uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- API requests use an ephemeral `URLSession` with cookies disabled.
- Only HTTPS endpoints are configured.
- Telegram links open only after an explicit tap.
- No analytics, advertising or tracking SDK.
- `PrivacyInfo.xcprivacy` declares no tracking or analytics collection.

## Known integration boundary

The old IPA uses private VK music methods and credentials belonging to another
client. This project intentionally does not copy its secret. The embedded login
uses VK's own public web-client identifier and web-token endpoint, while the
fallback accepts a user-owned VKpyMusic session. Direct `audio.*` calls work
only for tokens/accounts that VK permits to use them. An App Store release
should use official VK ID after registering an iOS application and bundle ID.
