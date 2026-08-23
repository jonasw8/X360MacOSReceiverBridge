# Self-contained Xcode project

Open `X360ControllerBridge.xcodeproj` and build/run the
**X360 Controller Bridge** scheme.

libusb 1.0.30 is included under `Vendor/libusb` and its Darwin sources are
compiled directly into the app target. No Homebrew, MacPorts, pkg-config,
CMake, Ninja or separately installed libusb is required.

The vendored libusb is LGPL-2.1-or-later. Its license is in
`Vendor/libusb/COPYING`.

All files under `scripts/` retain mode 0777.
