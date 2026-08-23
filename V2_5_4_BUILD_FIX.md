# v2.5.4 build fix

Fixes the v2.5.3 Objective-C++ build error after `controllerSnapshot()` gained
the battery research fields.

Wireless snapshots now pass:
- `slot.battery_candidate`
- `slot.battery_update_count`

Wired snapshots pass:
- `std::nullopt`
- `0`

No protocol, HID, rumble, Power Off, or battery research logic was otherwise
changed.
