# Architecture

Private Music 2.0 is a clean SwiftUI application, not a decompilation of the
original binary.

## Layers

- `App` creates a single dependency container.
- `Core` owns configuration, HTTPS transport and Keychain access.
- `Models` contains immutable `Sendable` domain values.
- `Services` isolates VK-specific response formats behind `MusicService`.
- `Session` owns the current access token and profile.
- `Player` owns `AVPlayer`, background audio, Now Playing and remote commands.
- `Features` contains SwiftUI screens and view models.

## Security decisions

- No password, OTP or CAPTCHA interception.
- No embedded `client_secret`.
- Session token uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- API requests use an ephemeral `URLSession` with cookies disabled.
- Only HTTPS endpoints are configured.
- Telegram links open only after an explicit tap.
- No analytics, advertising or tracking SDK.
- `PrivacyInfo.xcprivacy` declares no tracking or analytics collection.

## Known integration boundary

The old IPA uses private VK music methods and credentials belonging to another
client. This project intentionally does not copy those credentials. Direct
`audio.*` calls work only for tokens/accounts that VK permits to use them.
Official VK ID integration should be added with the official VK SDK after
registering a new iOS application and bundle ID.
