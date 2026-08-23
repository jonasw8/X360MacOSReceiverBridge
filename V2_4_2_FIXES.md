# v2.4.2 fixes

- Fixed a mutex deadlock in `handleWirelessEvent`: battery logging is now performed after releasing `_mutex`. This restores the receiver event thread and prevents input/HID updates from getting stuck.
- Added a visible Battery row to the main controller section.
- Kept the Battery entry in the menu bar controller menu.
- Corrected the battery unit tests so their raw flags match the implemented bit layout.
- No changes to input decoding, HID descriptors, or rumble commands.
