# v2.5.9 — Handshake Lab deadlock fix

v2.5.8 logged every USB OUT packet inside `Receiver::write_packet()`.

On controller connection, `macos_app.mm` holds its manager mutex while sending
the automatic LED command. `write_packet()` then invoked the log callback,
which attempted to acquire the same manager mutex again. Because the mutex is
not recursive, the app deadlocked exactly when the controller connected.

Fix:
- Removed UI logging from inside `Receiver::write_packet()`.
- Kept exact OUT packet logging in the explicit Battery Handshake Lab actions,
  where logging is safe and does not re-enter the controller-event mutex.
- Input, pairing, HID, battery research, rumble, Power Off, and profiles are
  otherwise unchanged.
