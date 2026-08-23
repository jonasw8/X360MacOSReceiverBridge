# v2.5.3 — Battery Research

This build is designed to discover the real Xbox 360 wireless battery status
format on the tested receiver/controller pair.

## UI

Battery now reports research state, for example:

`Unknown • initial candidate 0x63 • dedicated updates 0`

If a dedicated packet arrives:

`Unknown • dedicated raw 0xA2 • updates 1`

No percentage is invented.

## Diagnostics

For slot 1, every non-controller-input packet is logged and classified as:

- initial-announcement
- dedicated-battery
- presence/status
- unclassified

This is intentionally broader than the current battery parser so alternate
battery packet formats can be discovered.

Transient LIBUSB_ERROR_IO noise from unused slots 2–4 is suppressed unless
raw USB packet logging is enabled.

Input, rumble, Power Off, and HID profiles are unchanged.
