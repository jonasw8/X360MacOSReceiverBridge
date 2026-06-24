# Changelog

## 0.1.2

- Fixed Homebrew `libusb` compilation by including `<libusb.h>` from the
  include directory exported by `pkg-config`.
- Removed the compile-time dependency on
  `IOKit/hid/IOHIDUserDevice.h`, which is absent from some current Command
  Line Tools SDKs.
- Added runtime binding for the documented `IOHIDUserDevice` functions while
  retaining the macOS 13 deployment target.
- Kept virtual-HID creation failures explicit when the managed Apple
  entitlement is unavailable.

## 0.1.1

- Normalized future-dated files before a Ninja build to prevent repeated CMake
  regeneration after ZIP extraction across time zones.

## 0.1.0

- Initial receiver, decoder, virtual-HID prototype, tests, and documentation.
