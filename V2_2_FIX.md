# X360MacOSReceiverBridge v2.2

Build fix for the macOS HID inspector.

Changed:
- `kIOHIDOptionsNone` -> `kIOHIDOptionsTypeNone`

This matches the HIDKeys definitions exposed by the macOS SDK used for the build.
No receiver, protocol, or HID report behavior was changed.
