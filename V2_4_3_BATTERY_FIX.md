# v2.4.3 Battery fix

The previous v2.4.x incorrectly decoded the Xbox 360 Wireless Receiver battery
byte using xpadneo/Xbox One-style bit flags.  For the Xbox 360 wireless
receiver, xboxdrv treats the value as a raw 0..255 battery level:

- Initial announcement `00 0f 00 f0 ...`: byte 17
- Battery update `00 00 00 13 xx ...`: byte 4

The old macOS 360Controller preference pane converted its `BatteryLevel`
property with `level * 100 / 255`, so v2.4.3 follows that representation.

Example observed value:
- raw `0x63` = decimal 99 = about 39%

This release also logs the full packet that produced each battery update.
Input/HID and rumble logic are unchanged.
