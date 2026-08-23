# X360MacOSReceiverBridge v2.5

Based on v2.4.3.

## Added

### Power Off
Wireless controller rows now expose a dedicated **Power Off** button.
It calls the existing Xbox 360 Wireless Receiver power-off command through
`Receiver::power_off()`. The existing Disconnect action is preserved.

### Xbox Series X virtual HID profile
A third HID profile is available:

- Generic Joystick — 1209:0360
- Xbox 360 Controller — 045E:028E
- Xbox Series X Controller — 045E:0B12

The Series X profile publishes Microsoft VID/PID and Game Pad usage while
retaining the bridge's proven 14-byte virtual HID input report layout. This is
intended as a compatibility profile for macOS versions that recognize newer
Xbox controllers better than Xbox 360 controllers. It does not claim to clone
the physical USB protocol of a real Series X controller.

Changing the HID profile destroys the currently published virtual HID device;
the next controller state recreates it with the selected identity.

Input parsing, battery parsing, and Xbox 360 wireless rumble are unchanged.
