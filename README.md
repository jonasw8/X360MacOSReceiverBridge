# X360 Controller Bridge

A native macOS app for using Xbox 360 controllers with a USB receiver or a wired USB controller. The app keeps the old receiver/decoder work, but wraps it in a consumer-style Mac interface: a System Settings-inspired main window, menu-bar controls, guided “Add Controller” flows, native live-input rows, rumble testing, and details windows.

> [!IMPORTANT]
> The app uses a user-space virtual-HID path and shows a single native Privacy row when Accessibility approval is still required. It does not automatically open System Settings at launch, and it is not a magic entitlement bypass. Public distribution on stock macOS still needs a valid signing setup and Apple approval for `com.apple.developer.hid.virtual.device`. Local SIP/AMFI-disabled development machines can use the same user-space path for testing locally signed builds.

## What it supports

| Device path | Status |
|---|---|
| Xbox 360 wireless receiver `045e:0291`, `045e:02a9`, `045e:0719` | Implemented |
| Up to four wireless controller slots | Implemented |
| Wired Xbox 360 USB controller `045e:028e` | Added in 0.2.0 |
| Compatible third-party receiver/controller protocol matches | Opt-in compatibility mode |
| Native Mac main window and menu-bar app | Added in 0.2.0 |
| Virtual macOS HID joystick output | Implemented; requires permission/signing support |
| Rumble test and wireless power-off | Implemented from the app UI |
| Game-originated force feedback, battery level, headset audio, chatpad | Not implemented |

## The app flow

### Add a wireless controller

1. Open **X360 Controller Bridge.app**.
2. Click **Add Wireless Controller** or **Start Scanning**.
3. Plug in the Xbox 360 wireless receiver.
4. Press the receiver sync button.
5. Press the controller sync button.
6. When pairing completes, the controller appears in the connected-controller list and in the menu-bar menu.

Each connected wireless controller gets native live-input rows, a **Test Rumble** button, a **Details** window, and a **Disconnect** command that sends the receiver power-off command for that slot. Disconnected receiver slots stay hidden.

### Add a wired controller

1. Plug in an official wired Xbox 360 USB controller.
2. Open the app and click **Add Wired Controller** or **Start Scanning**.
3. The wired controller appears in the connected-controller list.
4. Use **Test Rumble**, **Details**, or **Disconnect** from the card or menu bar.

Wired support is intentionally conservative by default. Official Microsoft wired controllers are accepted automatically. Compatibility mode can try protocol-compatible third-party devices, but it should only be used on a development Mac where you are comfortable with USB diagnostics.

## Permissions

The app uses a user-space virtual-HID method. If macOS reports that Accessibility approval is missing, the app shows a single **Privacy** row with **Open System Settings…** and **Check Again**. It does not call the Accessibility prompt on launch, and the Privacy row disappears once macOS reports the app is allowed.

That gives the app a normal, user-visible permission flow without opening the same System Settings pane twice. It does not remove Apple’s managed entitlement requirement for a polished public build. For normal distribution, sign with a provisioning profile that actually contains:

```text
com.apple.developer.hid.virtual.device
```

The checked-in entitlements file declares the requested shape for a consumer build:

```text
com.apple.security.app-sandbox
com.apple.security.device.usb
com.apple.developer.hid.virtual.device
```

For local developer builds on machines with SIP/AMFI disabled, the app also includes a **Compatibility mode** setting. That mode keeps the user-space path and broad USB protocol matching available, similar to modern experimental macOS controller projects. It is not presented as a normal end-user install step.

## Build and launch on macOS

### Requirements

- macOS 13 or later
- Xcode or Xcode Command Line Tools
- CMake 3.22+
- `libusb-1.0`
- `pkg-config`
- Ninja, recommended

With Homebrew:

```sh
brew install cmake ninja pkg-config libusb
```

Build the native app bundle:

```sh
cd X360ReceiverBridge
./scripts/build-macos.sh
open "build/X360 Controller Bridge.app"
```

Package a locally signed ZIP for testing:

```sh
./scripts/package-macos-app.sh
```

The package helper bundles the `libusb` dylib into the app, updates the install name, signs the dylib and app, and writes:

```text
dist/X360-Controller-Bridge-0.2.0-macOS.zip
```

By default the package script uses ad-hoc signing, which is useful for local development and SIP/AMFI-disabled testing. For distribution, set a real identity and use a matching provisioning profile:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/package-macos-app.sh
```

Then notarize and staple using Apple’s standard Developer ID workflow.

## Advanced command-line mode

Double-clicking the app opens the native interface. Passing command-line flags preserves the previous developer workflow:

```sh
APP="build/X360 Controller Bridge.app/Contents/MacOS/X360 Controller Bridge"
"$APP" --help
"$APP" --list
"$APP" --no-hid --dump-state
```

Useful commands:

```text
--list                    list protocol-compatible wireless receivers
--receiver-index N        choose receiver from --list, default 0
--usb-id VID:PID          accept one explicit receiver USB ID
--allow-unknown           accept any FF/5D/81 wireless receiver protocol match
--no-hid                  decode only; do not create virtual HID
--dump-state              print decoded state changes
--dump-raw                print every USB packet
--deadzone N              per-axis square deadzone, 0..32767
--no-invert-y             preserve receiver Y-axis signs
--gamepad-usage           use HID Game Pad usage instead of Joystick
--virtual-vid HEX         override prototype virtual HID VID
--virtual-pid HEX         override prototype virtual HID PID
--led SLOT:MODE           send an Xbox LED mode, slot 1..4
--power-off SLOT          turn off a wireless controller in a slot
--rumble S:L:R[:MS]       one-shot wireless rumble test, values 0..255
```

The native app handles wired-controller discovery and bridging. The command-line mode remains focused on the original wireless receiver diagnostics.

## Compatibility notes

The generated virtual device is a generic HID joystick with:

- 16 button bits, with 11 currently assigned;
- one 8-way hat switch plus neutral;
- X/Y and Rx/Ry signed 16-bit axes;
- separate 8-bit trigger axes.

Good first test targets are SDL controller tests, Dolphin, OpenEmu, PCSX2, browser Gamepad API tests, and games that enumerate generic IOHID joysticks. Some games may still need manual mapping. Appearance in **System Settings → Game Controllers** is not a reliable pass/fail test because higher-level GameController routing can filter virtual HID devices.

## Source layout

```text
include/x360bridge/protocol.hpp          shared controller state model
include/x360bridge/receiver.hpp          wireless receiver libusb API
include/x360bridge/wired_controller.hpp  wired Xbox 360 USB controller API
include/x360bridge/hid_report.hpp        generic HID descriptor/report API
include/x360bridge/virtual_gamepad.hpp   virtual-device API and permission helpers
src/macos_app.mm                         native macOS AppKit interface
src/main.cpp                             advanced CLI and wireless bridge
src/receiver.cpp                         wireless receiver discovery/IO
src/wired_controller.cpp                 wired controller discovery/IO
src/virtual_gamepad_macos.mm             IOHIDUserDevice backend and permission request
src/virtual_gamepad_stub.cpp             non-macOS diagnostic stub
tests/protocol_tests.cpp                 protocol and HID unit tests
scripts/build-macos.sh                   native app build helper
scripts/package-macos-app.sh             local packaging/signing helper
docs/                                    architecture, research, migration, tests
```

## Safety

Remove or unload old Xbox 360 controller kernel-extension drivers before testing because they may already own the receiver interfaces. The normal app flow does not require root, a kernel extension, a privileged helper, or disabling macOS security. SIP/AMFI-disabled compatibility is kept as an explicit development option, not an end-user recommendation.

## License and acknowledgements

The project is GPL-2.0. The protocol implementation was informed by the GPL-licensed Linux `xpad` driver and historical macOS Xbox-controller work. See [NOTICE.md](NOTICE.md) and [docs/RESEARCH.md](docs/RESEARCH.md).


## V2 HID compatibility profiles

V2 adds a runtime HID profile selector and an IOHID registry inspector. The Xbox 360 profile uses the classic 045E:028E identity and Game Pad usage for compatibility testing; the original Generic Joystick 1209:0360 profile remains available.


## V2
Runtime HID identity profiles and an IOHID visibility inspector were added for compatibility testing with OpenEmu and other HID clients.
