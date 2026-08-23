# X360MacOSReceiverBridge v2.1

Build fix for the v2 HID compatibility/inspection UI.

- Added IOKit HID Manager and HID key headers to `src/macos_app.mm`.
- Added the missing `kHIDProfileKey` preference constant.
- No protocol, receiver, or virtual HID report logic was changed.
