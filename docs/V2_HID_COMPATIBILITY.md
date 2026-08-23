# V2 HID compatibility

V2 adds two runtime output identities without changing the receiver/protocol backend:

* Generic Joystick — VID/PID 1209:0360, usage Joystick (0x04).
* Xbox 360 Controller — VID/PID 045E:028E, manufacturer Microsoft, usage Game Pad (0x05).

Both use the same 14-byte report layout in this test build. This isolates identity/usage compatibility from packet decoding.

An IOHID inspector in the app enumerates X360 virtual devices currently visible to IOHIDManager.

Test with OpenEmu Input Monitoring enabled. Compare Generic vs Xbox 360 profile and record which profile OpenEmu detects. System Settings > Game Controllers is not treated as authoritative for IOHIDUserDevice.
