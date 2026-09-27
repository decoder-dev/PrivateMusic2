# Library features in 3.29.0

## Entry points

- Library → plus menu → Friends’ music: paged friend list, then tracks and playlists.
- Library → plus menu → Upload audio to VK: MP3 file picker, artist and title, bounded file-backed upload.
- Library → plus menu → Download entire library: Wi-Fi restriction, persistent per-account queue, pause/resume/cancel. Completed files remain after queue cancellation. Existing cached tracks become manual downloads.
- Owned playlist → actions → Edit: title, description, cover picker and hidden flag. A new hidden playlist includes `no_discover` in its creation request. Partial cover/visibility failure preserves the created playlist ID for retry.
- Settings → VK integration: status broadcasting and listening events, independently disabled by default. Switching accounts disables both. API rejection stops the affected integration and shows a retry action.
- Settings → Player audio → Crossfade: 0.5–10 seconds. Existing HLS/EQ/power/thermal exclusions remain.

## Validation and limitations

Local validation covers resources, localization, Swift syntax (not type checking), whitespace and symbol packaging tests. XCTest adds coverage for pagination, malformed playlist entries, hidden creation, clear-broadcast requests, denied VK requests, upload-host validation, queue account isolation and crossfade boundaries. CI compiles the app and runs the full suite on Xcode.

No device execution was available during implementation. VK's public schema documents `friends.get`, but does not expose all the audio, cover and playback-event methods used here. Their compatibility with a user's current VK session must be verified on device. A successful HTTP/API response to `stats.trackEvents` does not prove that recommendations changed. The client reports API errors instead of claiming success.

Bulk download is an app-lifetime operation with a durable queue, not an OS-guaranteed background transfer. After termination, open its screen and resume. An individual failed download pauses the queue at that track for retry. The page cursor describes the library at scan time; if tracks are added or removed during a long scan, run another scan after completion to reconcile changes.

Uploads and public status updates occur only through user actions/settings. Credentials and upload responses are not logged; event payloads are redacted. The privacy manifest declares the new VK sharing categories using Apple's published data-type identifiers. It does not enable cross-app advertising tracking.

## Device acceptance

1. Open friends with >100 entries; load later pages. Verify a restricted friend's music produces an error and that another friend still opens.
2. Create a hidden playlist; verify its visibility in VK. Change an existing cover; disconnect during upload, then retry without creating a duplicate playlist.
3. Upload an MP3, cancel another upload, and simulate an uncertain network response. Check VK before repeating a write whose result is unknown.
4. Download a library spanning multiple pages. Pause, relaunch, resume, exhaust storage and switch accounts. Confirm old queue metadata and audio never appear under the new account.
5. Enable status, play/pause/skip, disable status and inspect VK. Enable event reporting and verify server acceptance without claiming recommendation effects.
6. Compare 0.5/6/10-second crossfades on progressive streams and verify the existing exclusions. Exercise large text and VoiceOver on all new screens.

References: [VK friends schema](https://github.com/VKCOM/vk-api-schema/blob/master/friends/methods.json), [Apple privacy data types](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype).
