# ubox-stream

UBIA P4P camera stream client. Connects to a UBIA camera via relay servers and dumps H.265 video (optionally remuxed to MP4).

## Install

```
uv sync
```

## Usage

```
uv run ubox-stream --uid YOUR_CAMERA_UID --password YOUR_DEVICE_PASSWORD
uv run ubox-stream --uid ... --password ... --quality sd --duration 60
uv run ubox-stream --uid ... --password ... --mp4
```

With credentials from 1Password (`UBIA Camera` item):

```bash
uv run ubox-stream \
  --uid "$(op read 'op://Personal/UBIA Camera/username')" \
  --password "$(op read 'op://Personal/UBIA Camera/password')"
```
