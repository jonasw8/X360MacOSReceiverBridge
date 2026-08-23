# v2.5.2 Battery diagnostic fix

This version fixes the broken v2.5.1 source edit and keeps the intended
diagnostic behavior:

- Initial announcement byte 17 is logged only as a battery candidate.
- It is not shown as a battery percentage.
- Only dedicated `00 00 00 13 XX` packets are promoted to BatteryInfo.
- Dedicated values remain raw/unknown until hardware testing establishes the
  actual encoding.
- Input, rumble, Power Off, and HID profile behavior are unchanged.
