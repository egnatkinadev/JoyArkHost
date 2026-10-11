# JoyArk Host

A separate native macOS host for the JoyArk iPhone app. It streams a display from this Mac over the local network; games run on the Mac and are started by the user.

## Requirements

- macOS 13 or later and a recent Xcode with Swift 5.9 or later.
- JoyArk on an iPhone connected to the same Wi-Fi/Ethernet LAN as the Mac.
- Screen Recording permission for video and system audio.
- Accessibility permission for remote keyboard/mouse controls.

No account, cloud service, external streaming catalog, or bundled game content is used.

## Build and run

```sh
./scripts/build-app.sh
open "build/JoyArk Host.app"
```

The script builds the Release executable, assembles a local `.app` bundle with usage descriptions and Bonjour declarations, and signs it ad hoc. The public download is source code, not a notarized binary. The build script creates the app locally on your Mac. Keep the built app at a stable path so macOS can retain its permission grants. After changing or rebuilding the binary, macOS may require granting permissions again.

For development, open `Package.swift` in Xcode. For permission checks and normal use, run the assembled app rather than `swift run`: otherwise macOS can associate permissions with Terminal/Xcode instead of the app bundle.

## First connection

1. Open JoyArk Host, select the display, and allow Screen Recording in System Settings. Quit and reopen the host if macOS requests it.
2. To control the game remotely, allow Accessibility and keep **Allow keyboard and mouse control** enabled. Video works without Accessibility.
3. Press **Start Host**. The status changes to **Ready for iPhone** only after the listener is ready.
4. Open JoyArk on the iPhone and select this Mac in **Nearby Macs**. No address or key entry is needed.
5. Compare the six-digit code on both devices, then press **Allow iPhone** in the Mac's approval sheet only when the codes match. Reject unfamiliar requests or different codes. This first approval saves the connection securely on the iPhone; later connections use the saved pairing.
6. Launch or return to your game on the Mac and keep its window focused so keyboard/mouse input reaches it. Tap **Start streaming** on the iPhone. No capture starts merely because the host is listening or a phone has paired.

If the network has client isolation/guest Wi-Fi, the devices may not be able to reach each other. Use the same normal LAN. Allow incoming JoyArk Host connections if the macOS firewall prompts. Streaming uses TCP port `47991` and `_roomplay._tcp`; first approval uses port `47992` and `_roomplay-pair._tcp`. Both services advertise the same Mac name. The host excludes cellular/VPN interfaces, rejects peers with public IP addresses, and accepts one iPhone connection or pending approval at a time.

**Advanced pairing** contains the old QR/link and manual address/key fallback. Use it only if automatic pairing is unavailable. Manual addresses are bare private IPs or `.local` names, without a port suffix.

## Streaming and controls

- ScreenCaptureKit captures the selected display and optionally its system audio. The host's own windows and audio are excluded. Protected content may not be capturable.
- VideoToolbox encodes low-latency H.264 with frame reordering disabled. 720p/1080p caps, 30/60 FPS, and 2–40 Mbps are supported. The source aspect ratio is preserved without upscaling; actual performance depends on the Mac, phone, game and LAN.
- System audio is sent as stereo 48 kHz float PCM; audio traffic is skipped when a connection is congested. It does not capture the microphone.
- Encoder plus network video backlog is limited to two frames. Source frames are skipped before encoding under congestion. If an encoded frame cannot be sent, the host waits for a new keyframe instead of continuing a broken reference chain.
- Input is native keyboard/mouse event injection. A controller connected to the iPhone is mapped to those controls by the iPhone client. This host does **not** emulate a native macOS gamepad; controller-only games need separate support.
- A selected display is shared as a whole. Close sensitive windows and notifications before streaming. **Stop Session** ends capture while leaving the game running; **Stop Host** also closes the network listener. Sleep and app termination stop the host. Quitting or disconnecting releases held keys/buttons.

## Pairing security

The host's 32-byte cryptographically random streaming key is saved in the user's Keychain. During first approval, an ephemeral Curve25519 key agreement with a nonce commitment/reveal produces the matching six-digit verification code. After the Mac user explicitly allows the matching code, the streaming key is encrypted with the derived AES-GCM key and sent to the phone. The bootstrap channel never sends it in plaintext. The phone keeps its approved key in its own Keychain.

Unapproved bootstrap requests cannot view the display or inject input. The host accepts one pending request, limits new attempts to five per minute with at least three seconds between them, expires incomplete handshakes after 15 seconds and approval sheets after 90 seconds. Cancel, reject, host stop, sleep, disconnect and key replacement dismiss pending requests. Never approve a code without comparing it on your phone; device names alone are not proof of identity.

Subsequent streaming connections use the saved key as a TLS pre-shared secret: they negotiate TLS 1.2 with AES-256-GCM encryption and authenticate before the streaming hello/start exchange. Advanced QR codes and copied manual pairing links contain this secret. Share them only with trusted phones; do not put them in screenshots, logs, issues, or Git.

**Replace Pairing Key** stops the host, disconnects the current client and replaces the Keychain secret. Start the host again, forget the saved Mac on each phone and approve a fresh connection. Old keys can no longer authenticate. Phones do not receive control capabilities until Accessibility permission is granted and control is enabled on the host.

The application provides a local-network transport and no internet discovery, NAT traversal or relay. Do not forward its port through a router.

## Validation

```sh
swift test
cd RoomPlayKit && swift test
```

Host tests cover real local automatic pairing approval/rejection, cancellation and attempt limits, Retina/ultrawide aspect fitting, native relative mouse event fields and a production VideoToolbox H.264 encode → parameter sets/AVCC → hardware decode round trip using a test-only pixel buffer. The regular host suite includes an opt-in simulator pairing harness that is skipped unless explicitly enabled. No test data or automatic approval exists in the Release app. Shared-package tests validate framed messages, LAN addresses, pairing links and authenticated TLS transport.

Successful compilation and codec/transport tests do not prove a live screen/audio session or a particular game's input compatibility. Those require launching the assembled app, granting macOS permissions, connecting a physical iPhone and exercising a real game.

## Source layout

- `Sources/RoomPlayHost/`: SwiftUI host UI, Keychain secret management, listener, screen/audio capture, H.264 encoder and keyboard/mouse injection.
- `RoomPlayKit/`: app-local copy of the shared authenticated streaming protocol.
- `scripts/build-app.sh`: local Release app assembly and signing.
- `Tests/RoomPlayHostTests/`: test-only layout/codec validation.
