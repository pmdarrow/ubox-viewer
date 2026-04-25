# ubox-stream

Open-source, reverse-engineered tools for security cameras that use the [UBox](https://apps.apple.com/us/app/ubox/id1436112326) app. These are low-cost 4G/WiFi security and trail cameras sold on AliExpress, Amazon, etc. under brands like UBIA, i-Cam+, Soliom+, and others.

The cameras use a proprietary protocol (UBIA P4P) to stream H.265 video through UBIA's cloud relay infrastructure. This project provides:

- **[UBoxViewer](UBoxViewer/)** — Native macOS viewer app for live streaming
- **[UBoxStreamLib](UBoxStreamLib/)** — Swift library and CLI for connecting to cameras and recording streams

## Reverse engineering

The P4P protocol is proprietary and undocumented. It was reverse engineered using three approaches:

1. **APK decompilation** -- The UBIA Android app (UBox 1.1.360) was decompiled with jadx. The Java sources revealed the high-level protocol flow: API login, device discovery, session setup, and AV channel management. Key classes: `LiveViewNew2`, `UBICAPIs` (JNI bridge).

2. **Native library analysis with Ghidra** -- The core protocol lives in `libUBICAPIs.so` (ARM, loaded via JNI). Custom Ghidra scripts decompiled all `p4p_*` functions, revealing the packet format, session state machine, crypto (DWORD bit-shift + XOR + Swap cipher), CRC32 checksums, KCP reliable transport, and the RDT video framing layer.

3. **Network captures** -- Wireshark pcap of live traffic plus mitmproxy dumps of the HTTPS API (`portal.ubianet.com`) captured the full login flow, device list queries, and UDP P4P handshake/stream packets to correlate against the decompiled code.

## Build

### CLI

```
cd UBoxStreamLib
swift build -c release
```

### Viewer app

Open `UBoxViewer/UBoxViewer.xcodeproj` in Xcode and run the UBoxViewer scheme. A post-build script also copies the built app to `/Applications/UBox Viewer.app` so it can be launched from the Dock.

Credentials can be pre-filled via `UBOX_UID` and `UBOX_PASSWORD` environment variables (set in the scheme's Run configuration), or entered manually in the UI.

If Connect hangs at "Phase 1: Querying master servers" and the log at `~/Library/Caches/UBoxStream/stream.log` shows no replies arriving, do a clean rebuild (Product → Clean Build Folder, then Run). The macOS Application Firewall, when stealth mode is on, can silently drop inbound UDP replies to an adhoc-signed app whose code-signature hash has been stale-cached. A fresh build re-signs the binary and clears the issue.

## Usage

### CLI recorder

```
cd UBoxStreamLib
swift run ubox-stream --uid YOUR_CAMERA_UID --password YOUR_DEVICE_PASSWORD
swift run ubox-stream --uid ... --password ... --quality sd --duration 60
swift run ubox-stream --uid ... --password ... --mp4
```

## Security disclaimer

These cameras offer **no meaningful encryption** for video streams. The P4P protocol uses a trivial obfuscation cipher (bit-shifts, XOR, byte swaps) with no key exchange — anyone with access to the network traffic or UBIA's relay servers can decode the video in real time. The full cipher implementation is public in this repository.

Do not rely on these cameras for anything you would consider private. They may be acceptable for non-sensitive use cases like wildlife monitoring.
