# ubox-viewer (Python)

UBIA P4P camera stream client.

## Install

```
uv sync
```

## Usage

```
uv run ubox-viewer --uid YOUR_CAMERA_UID --password YOUR_DEVICE_PASSWORD
uv run ubox-viewer --uid ... --password ... --quality sd --duration 60
uv run ubox-viewer --uid ... --password ... --mp4
```

With credentials from 1Password (`UBIA Camera` item):

```bash
uv run ubox-viewer \
  --uid "$(op read 'op://Personal/UBIA Camera/username')" \
  --password "$(op read 'op://Personal/UBIA Camera/password')"
```
