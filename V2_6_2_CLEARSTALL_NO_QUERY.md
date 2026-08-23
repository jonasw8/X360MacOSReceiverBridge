# v2.6.2 — ClearStall recovery + Query Battery removal

This version keeps the accurate 360Controller 0.16.5 startup behavior and
focuses the USB read path on one concrete difference from the old macOS driver.

## USB read recovery

360Controller 0.16.5 called `ClearStall()` after controller input pipe overruns
and then resumed reading.

The bridge now mirrors that behavior with `libusb_clear_halt()` when a slot
read returns:

- `LIBUSB_ERROR_PIPE`
- `LIBUSB_ERROR_OVERFLOW`
- `LIBUSB_ERROR_IO`

The slot-1 diagnostic log records both the original read error and the result
of `libusb_clear_halt()`.

## Removed

The **Query Battery** button and its `GET_REPORT 0x04` implementation were
removed because the original Xbox 360 Wireless Receiver consistently rejects
that request with `LIBUSB_ERROR_PIPE`.

## Retained

- Accurate 360Controller 0.16.5 startup timing
- initial battery from `00 0f ... 13 XX`
- dynamic `00 00 00 13 XX` detection
- battery protocol research logging
- rumble
- Power Off
- HID profiles
- Handshake Lab

All files under `scripts/` remain mode 0777.
