# ubox-stream (Swift)

UBIA P4P camera stream client.

## Background

The P4P protocol is proprietary and undocumented. It's used by a number of low-cost security and trail cameras sold on AliExpress, Amazon, etc. under brands like UBIA. These cameras use the UBox app and communicate through UBIA's cloud infrastructure.

## Reverse engineering

The protocol was reverse engineered using three approaches:

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

Open `UBoxViewer/UBoxViewer.xcodeproj` in Xcode and run the UBoxViewer scheme.

Credentials can be pre-filled via `UBOX_UID` and `UBOX_PASSWORD` environment variables (set in the scheme's Run configuration), or entered manually in the UI.

## Usage

### CLI recorder

```
cd UBoxStreamLib
swift run ubox-stream --uid YOUR_CAMERA_UID --password YOUR_DEVICE_PASSWORD
swift run ubox-stream --uid ... --password ... --quality sd --duration 60
swift run ubox-stream --uid ... --password ... --mp4
```

With credentials from 1Password (`UBIA Camera` item):

```bash
cd UBoxStreamLib
swift run ubox-stream \
  --uid "$(op read 'op://Personal/UBIA Camera/username')" \
  --password "$(op read 'op://Personal/UBIA Camera/password')"
```
