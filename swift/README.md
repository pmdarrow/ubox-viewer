# ubox-stream (Swift)

UBIA P4P camera stream client.

## Build

```
swift build -c release
```

## Usage

```
swift run ubox-stream --uid YOUR_CAMERA_UID --password YOUR_DEVICE_PASSWORD
swift run ubox-stream --uid ... --password ... --quality sd --duration 60
swift run ubox-stream --uid ... --password ... --mp4
```

With credentials from 1Password (`UBIA Camera` item):

```bash
swift run ubox-stream \
  --uid "$(op read 'op://Personal/UBIA Camera/username')" \
  --password "$(op read 'op://Personal/UBIA Camera/password')"
```
