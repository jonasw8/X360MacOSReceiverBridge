# X360 Controller Bridge

X360 Controller Bridge is a native macOS application that bridges Xbox 360 controllers to modern macOS through USB and a user-space virtual HID device. It supports the original Xbox 360 Wireless Gaming Receiver as well as official wired Xbox 360 USB controllers.

The project preserves the receiver/protocol work inspired by the historical macOS Xbox 360 driver while providing a modern SwiftUI/AppKit interface, menu-bar controls, controller diagnostics, runtime HID profiles, rumble, wireless power-off, DSU/Cemuhook output, and an Xcode project that can be built without locating a separate system copy of `libusb`.

> [!IMPORTANT]
> The virtual-controller backend uses `IOHIDUserDevice`. Public distribution on a normal macOS installation still requires appropriate code signing and Apple's `com.apple.developer.hid.virtual.device` entitlement. The project does not bypass that requirement.

## Current features

| Feature | Status |
|---|---|
| Original Xbox 360 Wireless Gaming Receiver `045e:0291`, `045e:02a9`, `045e:0719` | Implemented |
| Up to four wireless receiver slots | Implemented |
| Official wired Xbox 360 USB controller `045e:028e` | Implemented |
| Compatible third-party protocol matches | Optional compatibility mode |
| Native macOS SwiftUI/AppKit application | Implemented |
| Menu-bar controller controls | Implemented |
| User-space virtual HID controller | Implemented |
| Runtime HID identity/profile selection | Implemented |
| Generic Joystick profile `1209:0360` | Implemented |
| Xbox 360 profile `045e:028e` | Implemented |
| Xbox Series X profile `045e:0b12` | Implemented |
| IOHID registry inspector | Implemented |
| Wireless rumble test | Implemented |
| Wireless controller power-off | Implemented |
| DSU/Cemuhook UDP output | Implemented |
| Brazilian Portuguese localization | Implemented |
| Self-contained Xcode `libusb` dependency | Implemented |
| Dynamic Xbox 360 wireless battery level | Under investigation |
| Game-originated force feedback | Not implemented |
| Headset audio / chatpad | Not implemented |

## Xcode project

The repository includes:

```text
X360ControllerBridge.xcodeproj
```

Open it directly in Xcode:

```sh
open X360ControllerBridge.xcodeproj
```

Then select the **X360ControllerBridge** scheme and build/run the application.

### Self-contained libusb

The Xcode project contains the required `libusb` files inside the repository. Xcode does not need to discover a Homebrew/MacPorts installation of `libusb` in order to compile the application.

This makes the Xcode project reproducible and avoids build failures caused by different `libusb` versions installed on the development Mac.

The command-line/CMake development workflow may still use a system installation depending on how it is invoked.

## Localization

The application now supports:

- English (`en`)
- Português do Brasil (`pt-BR`)

Translations are stored in the Xcode String Catalog:

```text
Resources/Localizable.xcstrings
```

Xcode can edit the catalog directly. Select **Localizable.xcstrings** in the project navigator to view and modify each language.

The application follows the language selected by macOS for the app. No separate in-app language selector is required.

The localization covers the main window, sidebar, controller actions, scanning controls, settings, diagnostics, battery labels, menu-bar commands, USB/controller descriptions, and common status messages.

Additional implementation notes are available in:

```text
README_LOCALIZATION.md
```

## Using a wireless Xbox 360 controller

1. Connect the Xbox 360 Wireless Gaming Receiver.
2. Open **X360 Controller Bridge**.
3. Start scanning if scanning is not already active.
4. Press the synchronization button on the receiver.
5. Press the synchronization button on the Xbox 360 controller.
6. After pairing, the controller appears in the **Game Controllers** section.

The application exposes controller input through its virtual HID backend when virtual-device creation is available.

From the controller panel you can also:

- test rumble;
- send the wireless power-off command;
- inspect live controller state;
- inspect output status;
- use the experimental handshake diagnostics.

## Wired Xbox 360 controllers

Official Microsoft wired Xbox 360 USB controllers are detected directly.

Connect the controller and enable scanning. Compatible third-party devices can optionally be tested through **Compatibility mode**, but protocol compatibility is not guaranteed.

## HID profiles

The virtual controller identity can be changed at runtime without rebuilding the application.

### Generic Joystick

```text
VID:PID 1209:0360
HID usage: Joystick
```

This is the original generic virtual-controller profile.

### Xbox 360 Controller

```text
VID:PID 045e:028e
HID usage: Game Pad
```

This profile advertises the classic wired Xbox 360 Controller identity.

### Xbox Series X Controller

```text
VID:PID 045e:0b12
HID usage: Game Pad
```

This profile advertises an Xbox Series X controller identity while retaining the bridge's proven input-report layout for compatibility testing.

After changing profiles, reconnect the controller or restart scanning so clients can enumerate the new virtual device.

Different applications use different controller APIs. A profile working in OpenEmu or another HID client does not guarantee identical behavior in Steam or every game.

## IOHID Inspector

The **Output** section contains an IOHID inspector that enumerates X360 virtual HID devices currently published in the macOS IOHID registry.

This is useful for separating several stages of controller recognition:

```text
USB receiver/controller
        ↓
X360 Controller Bridge
        ↓
IOHIDUserDevice
        ↓
IOHID registry
        ↓
SDL / Gamepad API / emulator / game
```

Appearance in **System Settings → Game Controllers** is not by itself a definitive success or failure test.

## Rumble and wireless power-off

Wireless controller output commands are supported from the application.

**Test Rumble** sends a short vibration command to the selected controller.

**Power Off** sends the receiver command used to turn off the selected wireless Xbox 360 controller.

These features are useful independently of virtual HID publication and are also helpful when testing receiver communication.

## Battery research

Battery reporting for the Xbox 360 wireless controller remains experimental.

The receiver sends an initial 29-byte announcement similar to:

```text
00 0f 00 f0 00 cc e1 45 7c 00 0d dd 48 81 00 05 13 63 20 1d 30 03 40 01 50 01 ff ff ff
```

The current research build records byte 17 (`0x63` in the example) as the legacy initial battery candidate. This can produce an initial percentage estimate, but testing showed that the value does **not** update as the batteries discharge.

Therefore the initial value must not currently be interpreted as a reliable live battery percentage.

The receiver also emits packets such as:

```text
00 f8 01 00 ...
00 f8 02 00 ...
```

These have been identified by the diagnostic work as wireless-link/RSSI-related traffic rather than dynamic battery updates.

Experiments with HID `GET_REPORT 0x04` returned `LIBUSB_ERROR_PIPE` on the original Microsoft receiver, so the old **Query Battery** UI action was removed.

The project also reproduces parts of the historical 0.16.5 initialization behavior, including the `weirdStart`/LED sequence, while watching for the dedicated battery-update packet used by the old driver. Dynamic battery updates have not yet been observed in the current user-space implementation.

See the `V2_5_*`, `V2_6_*`, and research documentation for the experimental history.

## Historical 0.16.5 compatibility research

The original macOS Xbox 360 driver version 0.16.5 worked with the Xbox 360 Wireless Gaming Receiver on older macOS releases such as Catalina.

The current project contains diagnostic work reproducing relevant portions of that receiver initialization flow.

In particular, the bridge can send the historical `weirdStart` command:

```text
00 00 00 40 00 00 00 00 00 00 00 00
```

and the receiver LED command used during initialization.

These experiments are retained for protocol research, especially for determining what caused the old driver to receive dynamic wireless battery events.

They are not required for normal controller input, rumble, or power-off operation.

## DSU / Cemuhook

The application can publish controller state over the DSU/Cemuhook protocol.

Default endpoint:

```text
UDP 127.0.0.1:26760
```

This can be used by compatible emulators and diagnostic clients. Rumble requests received through the DSU path can be forwarded to the matching bridged controller.

## Permissions and virtual HID

The virtual controller uses a user-space `IOHIDUserDevice` backend.

If macOS requires Accessibility approval, the application displays the corresponding status and provides a button to open the relevant System Settings page.

For normal public distribution, Apple approval/signing is still required for:

```text
com.apple.developer.hid.virtual.device
```

The project also contains USB-related entitlements required by its architecture.

Development systems with SIP/AMFI disabled may be useful for local experiments, but that is a development environment rather than an end-user installation method.

## Building with the helper scripts

The project retains the CMake/script workflow in addition to the Xcode project.

Typical development requirements are:

- macOS 13 or later;
- Xcode / Xcode Command Line Tools;
- CMake 3.22+;
- Ninja;
- `pkg-config`;
- `libusb-1.0` when using the CMake workflow.

Example Homebrew setup:

```sh
brew install cmake ninja pkg-config libusb
```

Build:

```sh
./scripts/build-macos.sh
```

Launch:

```sh
open "build/X360 Controller Bridge.app"
```

The scripts directory is intentionally distributed with permissive executable permissions for the current development/testing workflow.

## Packaging

The packaging helper creates the application bundle and packages the required `libusb` dynamic library with it.

Depending on the current script name in the checkout, run the packaging helper from `scripts/`.

Development builds can use ad-hoc signing. Public distribution requires a proper Developer ID identity, compatible entitlements, notarization, and stapling.

## Command-line diagnostics

The native executable retains command-line support for receiver development and diagnostics.

Examples:

```sh
APP="build/X360 Controller Bridge.app/Contents/MacOS/X360 Controller Bridge"

"$APP" --help
"$APP" --list
"$APP" --no-hid --dump-state
```

Useful options include:

```text
--list
--receiver-index N
--usb-id VID:PID
--allow-unknown
--no-hid
--dump-state
--dump-raw
--deadzone N
--no-invert-y
--gamepad-usage
--virtual-vid HEX
--virtual-pid HEX
--led SLOT:MODE
--power-off SLOT
--rumble S:L:R[:MS]
```

## Project layout

```text
X360ControllerBridge.xcodeproj           native Xcode project

Resources/
  Localizable.xcstrings                  English / Brazilian Portuguese catalog

include/x360bridge/
  protocol.hpp                           shared controller/protocol model
  receiver.hpp                           wireless receiver API
  wired_controller.hpp                   wired Xbox 360 controller API
  hid_report.hpp                         virtual HID descriptor/report API
  virtual_gamepad.hpp                    virtual-device API

src/
  X360BridgeApp.swift                    SwiftUI application and main interface
  X360BridgeManager.h                    Swift / Objective-C++ bridge interface
  X360Bridge-Bridging-Header.h           Swift bridging header
  macos_app.mm                           macOS bridge/backend integration
  receiver.cpp                           wireless receiver discovery and I/O
  wired_controller.cpp                   wired controller discovery and I/O
  protocol.cpp                           Xbox 360 protocol parsing
  hid_report.cpp                         HID reports/descriptors
  virtual_gamepad_macos.mm               IOHIDUserDevice backend
  virtual_gamepad_stub.cpp               non-macOS diagnostic stub
  X360DiagnosticDSUServer.swift          DSU/Cemuhook server
  DeveloperLabEnvironment.swift          development-environment diagnostics
  main.cpp                               CLI entry point

scripts/
  build-macos.sh                         CMake/macOS build helper
  inspect-usb.sh                         USB diagnostic helper
  package-macos-app.command              packaging helper

tests/
  protocol_tests.cpp                     protocol/HID tests

docs/
  ARCHITECTURE.md
  DRIVERKIT_MIGRATION.md
  RESEARCH.md
  TESTING.md
  V2_HID_COMPATIBILITY.md
```

## Testing order

When diagnosing virtual-controller compatibility, test the layers separately:

1. Confirm the physical receiver or wired controller is detected.
2. Confirm controller input is visible inside X360 Controller Bridge.
3. Confirm the virtual HID device is created.
4. Use the IOHID inspector to confirm registry visibility.
5. Test a HID/SDL/Gamepad API client.
6. Test the target emulator or game.

This avoids treating a single application's controller-detection behavior as proof that the USB bridge itself is failing.

## Legacy driver conflicts

Old Xbox 360 macOS kernel-extension drivers should be removed or unloaded before testing this project. An old driver can claim the receiver's USB interfaces before the user-space bridge can access them.

The normal bridge architecture does not require a new kernel extension.

## Documentation

Development notes are kept in the repository, including the battery/protocol experiments and the transition from the original bridge to the current native application.

Notable files include:

```text
README_LOCALIZATION.md
V2_4_BATTERY.md
V2_5_POWER_OFF_SERIES_X.md
V2_5_3_BATTERY_RESEARCH.md
V2_5_5_BATTERY_QUERY_LAB.md
V2_5_6_BATTERY_PROTOCOL_HUNT.md
V2_5_8_BATTERY_HANDSHAKE_LAB.md
V2_5_9_DEADLOCK_FIX.md
V2_6_0_0165_INIT_LAB.md
V2_6_1_0165_ACCURATE_STARTUP.md
V2_6_2_CLEARSTALL_NO_QUERY.md
```

## License and acknowledgements

The project is GPL-2.0.

The Xbox 360 protocol implementation and research were informed by the GPL-licensed Linux `xpad` driver and historical macOS Xbox controller projects, including the behavior of the older 0.16.5 macOS driver.

See:

```text
NOTICE.md
docs/RESEARCH.md
```

for additional acknowledgements and research notes.
