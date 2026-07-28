# Private Music — premium UI execution prompt

Design and implement a premium, restrained iOS music application for
Private Music. Use native SwiftUI and Apple interaction conventions rather
than decorative imitation. The result must feel calm, fast and intentional.

## Visual direction

- Use SF Pro with a consistent semantic type scale. Monospaced digits are
  reserved for playback time and technical values.
- Default to a light pearl canvas with one user-selected accent. Dark themes
  remain available but must preserve contrast and hierarchy.
- Prefer whitespace, large artwork, 20–24 pt cards, subtle one-pixel borders
  and restrained shadows. Avoid saturated full-screen gradients.
- Liquid Glass is progressive enhancement on iOS 26. Every component must
  have a clean material or opaque fallback.
- Every loading, empty, error, offline and unavailable-stream state needs an
  explicit message and a recovery action where recovery is possible.

## Navigation and gestures

All gestures must have a visible button alternative and must not override the
system back gesture.

| Surface | Gesture | Result |
| --- | --- | --- |
| Main lists | Pull down | Refresh current remote content |
| Track row | Tap | Start playback without changing layout |
| Track row | Long press | Play next / open player |
| Library track | Swipe left | Remove after the system destructive affordance |
| Search track | Swipe left | Add to library |
| Mini-player | Tap | Open full player |
| Mini-player | Swipe up | Open full player |
| Mini-player | Swipe left | Next track |
| Mini-player | Swipe right | Previous track |
| Player artwork | Swipe left | Next track |
| Player artwork | Swipe right | Previous track |
| Player artwork | Swipe up | Open queue |
| Modal player | Swipe down | Dismiss player |
| Progress slider | Drag | Seek with continuous time feedback |
| Horizontal carousels | Swipe horizontally | Browse only that carousel |

Do not add global tab-swiping because it conflicts with the system back
gesture, playback artwork gestures and horizontal catalog carousels.

## Motion and feedback

- Use short spring feedback only for direct manipulation.
- Respect Reduce Motion; remove artwork rotation/translation when enabled.
- Use light haptics for selection, medium haptics for track changes and
  notification feedback for failures.
- Never animate a container in a way that changes the content viewport height.
  The mini-player overlays content above the tab bar.

## Functional quality bar

- Keep the VK session renewable in the device-only Keychain.
- Resolve owner/user identifiers before private VK music requests.
- Show buffering and playback failures in the player.
- Preserve background audio, Now Playing and remote commands.
- Keep every touch target at least 44×44 pt and provide accessibility labels.
- Avoid hidden-only features: gestures supplement visible controls.

Execute this specification in the production SwiftUI source, validate both
simulator and arm64 iPhone builds, then publish an unsigned IPA release.
