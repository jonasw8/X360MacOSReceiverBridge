# Notices and acknowledgements

X360ReceiverBridge is licensed under GPL-2.0.

The Xbox 360 receiver protocol and device identity research was informed primarily by the Linux kernel `xpad` driver:

- Linux source: `drivers/input/joystick/xpad.c`
- Repository: https://github.com/torvalds/linux
- License: GPL-2.0

Historical architecture and compatibility context came from:

- 360Controller/TattieBogle lineage: https://github.com/360Controller/360Controller
- experimental DriverKit port: https://github.com/noah-nuebling/mac-gamepad-driver
- Karabiner DriverKit virtual HID example: https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice
- SillyUtility VirtualController: https://github.com/SillyUtility/VirtualController
- Lumen virtual-gamepad experiment: https://github.com/trollzem/Lumen

The code in this repository is a compact, independent implementation of the required receiver decoding and HID mapping rather than a direct source-file port. Project and product names are used for identification and interoperability. Xbox is a trademark of Microsoft; this project is not affiliated with or endorsed by Microsoft or Apple.
