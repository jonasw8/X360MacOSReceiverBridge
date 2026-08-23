# v2.6.1 — 360Controller 0.16.5 Accurate Startup

This build corrects the timing of the 0.16.5 wireless startup emulation.

## Accurate order

1. Receiver reports connected (`08 80`).
2. Initial controller information arrives (`00 0f ...`).
3. If byte 16 is `0x13`, byte 17 is accepted as initial BatteryLevel.
4. The bridge sends the exact 0.16.5 `weirdStart`:
   `00 00 00 40 00 00 00 00 00 00 00 00`
5. When LED setup occurs, the bridge mirrors 0.16.5 SetLEDs:
   LED command, then `weirdStart`.

## Battery

The initial `00 0f ... 13 XX` value is again treated as the initial battery
level, matching 360Controller 0.16.5.

The displayed percentage uses the legacy conversion:
`raw * 100 / 255`, rounded.

The UI shows whether the value is from the Initial report or a Dynamic update,
plus the count of `00 00 00 13 XX` updates.

## Scripts

All files under `scripts/` are packaged with mode 0777.
