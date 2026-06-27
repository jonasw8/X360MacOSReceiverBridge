# Changelog

## 0.2.0

- Added a native macOS AppKit interface with a main window, menu-bar controls,
  guided wireless/wired controller add flows, System Settings-style controller
  groups, detail windows, rumble testing, and disconnect actions.
- Added wired Xbox 360 USB controller discovery and input decoding for the
  official `045e:028e` controller, with opt-in protocol-match compatibility.
- Added a user-space HID permission helper and changed the app UI to show one
  native Privacy row only while Accessibility approval is missing.
- Added a compatibility setting for locally signed development builds on
  SIP/AMFI-disabled Macs without making weakened system security a normal
  install step.
- Changed the macOS bundle name to `X360 Controller Bridge.app` and added a
  packaging helper that bundles `libusb`, signs locally, and writes a ZIP.
- Updated the README and architecture notes for the consumer app flow.

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
