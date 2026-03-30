# ubox-viewer

Open-source, reverse-engineered tools for security cameras that use the [UBox](https://apps.apple.com/app/ubox-cam/id1590592498) app. These are low-cost 4G/WiFi security and trail cameras sold on AliExpress, Amazon, etc. under brands like UBIA, i-Cam+, Soliom+, and others.

The cameras use a proprietary protocol (UBIA P4P) to stream H.265 video through UBIA's cloud relay infrastructure. This project provides:

- **[UBoxViewer](swift/UBoxViewer/)** — Native macOS viewer app for live streaming
- **[UBoxStreamLib](swift/UBoxStreamLib/)** — Swift library and CLI for connecting to cameras and recording streams
- **[Python client](python/)** — Python library and CLI for connecting to cameras and recording streams
