# v2.5.5 — Battery Query Lab

This experimental build adds a **Query Battery** button for wireless Xbox 360
controllers.

When pressed, the app:

1. Sends a class/interface `GET_REPORT` request for input Report ID `0x04`
   (`bmRequestType=0xA1`, `bRequest=0x01`, `wValue=0x0104`).
2. Logs the raw response if the receiver accepts the request.
3. Logs the libusb error if the receiver rejects/stalls the request.
4. Sends the existing receiver presence/status refresh.
5. Keeps the v2.5.4 slot-1 research logger active to capture any subsequent
   initial, dedicated-battery, presence/status, or unclassified packet.

A failure such as `LIBUSB_ERROR_PIPE` is considered useful research data, not
an application failure.

No battery percentage is inferred. Input, rumble, Power Off, and HID profiles
are unchanged.
