# ubox-viewer

An open-source, reverse-engineered viewer and stream client for security cameras that use the [UBox](https://apps.apple.com/app/ubox-cam/id1590592498) app. These are low-cost 4G/WiFi security and trail cameras sold on AliExpress, Amazon, etc. under brands like UBIA, i-Cam+, Soliom+, and others.

The cameras use a proprietary protocol (UBIA P4P) to stream H.265 video through UBIA's cloud relay infrastructure. This project provides a native macOS viewer app and CLI tools (Swift and Python) that connect directly to the cameras without the official app.

Available in [Python](python/) and [Swift](swift/).
