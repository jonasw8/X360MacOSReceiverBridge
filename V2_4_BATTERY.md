# X360MacOSReceiverBridge v2.4 — battery status

Adds wireless-controller battery status without changing the working HID/input or rumble path.

## Protocol sources used

- `xboxdrv`: initial 29-byte announcement uses byte 17 for battery status; a dedicated
  battery message starts with `00 00 00 13` and carries battery flags in byte 4.
- `xpadneo`: battery flag layout:
  - bit 7: online
  - bit 4: charging
  - bits 3..2: power mode (0 USB, 1 disposable batteries, 2 Play & Charge)
  - bits 1..0: capacity level (0 critical, 1 low, 2 medium, 3 full)

The app displays a qualitative state rather than pretending the 0..3 values are exact percentages.
Raw flags are shown for diagnostics.
