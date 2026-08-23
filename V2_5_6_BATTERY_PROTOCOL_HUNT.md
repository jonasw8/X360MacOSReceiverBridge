# v2.5.6 — Battery Protocol Hunt

Focuses battery research on two protocol signatures:

1. XUSB `bType == 0x09` (Battery PID Packet candidate).
2. Receiver packet `00 00 00 13 XX` observed by xboxdrv.

Changes:
- `00 F8 01/02 ...` is now classified as `wireless-link-rssi`, not battery.
- Slot 1 logs every non-input packet with better classification.
- Any packet matching the bType 0x09 heuristic is logged as
  `battery-pid-0x09`.
- Dedicated `00 00 00 13` packets remain logged separately.
- UI battery research line shows counts for dedicated updates and bType 0x09
  candidates.
- No percentage is inferred.
- Query Battery remains available from v2.5.5.

Input, rumble, Power Off, and HID profiles are unchanged.
