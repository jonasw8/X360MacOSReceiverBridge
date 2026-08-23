# v2.5.8 — Battery Handshake Lab

Adds controlled handshake experiments for the original Xbox 360 Wireless
Receiver while keeping the existing Battery Protocol Hunt diagnostics.

## New UI

Wireless controller rows now include a **Handshake Lab** menu:

- A: Presence → LED
- B: LED → Presence
- C: Presence → LED → Presence

Each step waits 150 ms before the next command.

## OUT logging

Every USB OUT packet sent to slot 1 is now logged, for example:

`slot 1 OUT packet=00 00 08 c0 00 00 00 00 00 00 00 00`

This makes it possible to compare exact OUT/IN ordering against xboxdrv and
other known receiver implementations.

## Existing research retained

- `00 F8 ...` classified as wireless-link-rssi
- bType 0x09 Battery PID candidate detection
- `00 00 00 13 XX` dedicated battery packet detection
- Query Battery / GET_REPORT experiment
- No fake battery percentage

Input, rumble, Power Off, and HID profiles are unchanged.
