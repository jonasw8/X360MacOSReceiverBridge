# v2.6.0 — 360Controller 0.16.5 Init Lab

This version ports the exact `weirdStart` command used by the old macOS
360Controller 0.16.5 wireless path:

`00 00 00 40 00 00 00 00 00 00 00 00`

## Automatic startup

On the first transition of a wireless slot from disconnected to connected,
the bridge now reproduces the 0.16.5 startup sequence:

1. `weirdStart`
2. LED command (`00 00 08 46 ...` for slot 1)
3. `weirdStart` again

The sequence is sent without logging from inside Receiver methods, avoiding
the mutex re-entry deadlock fixed in v2.5.9.

## Manual research action

Handshake Lab contains **Send exact 0.16.5 Init** so the same sequence can be
re-issued manually while diagnostics are running.

The existing battery protocol research remains active, especially watching for:

`00 00 00 13 XX`

No percentage mapping is changed in this research build.

All files under `scripts/` are packaged with mode 0777 as requested.
