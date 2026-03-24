# ubox-stream

UBIA P4P camera stream client. Connects to a UBIA camera via relay servers and dumps H.265 video (optionally remuxed to MP4).

Available in [Python](python/) and [Swift](swift/).

## Usage

### Python

```
cd python
uv sync
uv run ubox-stream --uid YOUR_CAMERA_UID --password YOUR_DEVICE_PASSWORD
```

### Swift

```
cd swift
swift build -c release
swift run ubox-stream --uid YOUR_CAMERA_UID --password YOUR_DEVICE_PASSWORD
```

### Options

```
--uid            Camera UID (required)
--password       Device password (required)
--username       Device username (default: admin)
-q, --quality    Stream quality: hd or sd (default: hd)
-o, --output     Output file path
--mp4            Remux to MP4 after recording (requires ffmpeg)
-d, --duration   Recording duration in seconds (default: 30)
-t, --timeout    Connection timeout in seconds (default: 30)
-v, --verbose    Enable debug logging
```

With credentials from 1Password (`UBIA Camera` item):

```bash
ubox-stream \
  --uid "$(op read 'op://Personal/UBIA Camera/username')" \
  --password "$(op read 'op://Personal/UBIA Camera/password')"
```
