# X360ReceiverBridge

A research-grade macOS bridge for **Xbox 360 wireless controllers connected through a USB wireless receiver**. It reads the receiver in user space, decodes up to four controller slots, and attempts to publish each connected controller as a generic HID joystick.

> [!IMPORTANT]
> This is source code and a hardware test prototype, not a pre-signed drop-in driver. The USB/receiver side is conventional user-space code. The system-wide virtual-gamepad side is constrained by an Apple-managed entitlement and by macOS game-controller routing behavior. Read [Status and constraints](#status-and-constraints) before building.

## What this project does

```text
Xbox 360 controller
       ⇅ proprietary 2.4 GHz link (handled by the receiver)
USB wireless receiver
       ⇅ four vendor-specific FF/5D/81 controller interfaces
libusb receiver service
       ⇢ packet decoder ⇢ normalized per-slot state
       ⇢ IOHIDUserDevice ⇢ generic HID joystick ⇢ IOHID / SDL-aware apps
```

The implementation:

- recognizes the established Microsoft receiver IDs `045e:0291`, `045e:02a9`, and `045e:0719`;
- can accept another receiver ID explicitly, or inspect an unknown device that exposes the same `FF/5D/81` interface protocol;
- claims up to four controller interfaces and reads them concurrently;
- decodes buttons, D-pad, triggers, both sticks, connection status, and headset-presence status;
- sends receiver presence, LED, rumble-test, and power-off protocol commands;
- creates one generic virtual HID joystick per connected controller;
- has a decode-only mode that works without virtual-HID access;
- avoids a legacy kernel extension and never asks you to weaken System Integrity Protection or AMFI.

## Status and constraints

| Part | Status |
|---|---|
| Receiver discovery and interface matching | Implemented |
| Official/common-clone USB IDs | Implemented |
| Unknown protocol-compatible clone override | Implemented, opt-in |
| Four wireless controller slots | Implemented |
| Input packet decoding | Implemented and unit-tested |
| LED and one-shot rumble commands | Implemented |
| Generic HID report generation | Implemented and unit-tested |
| macOS `IOHIDUserDevice` backend | Implemented, but requires Apple approval/signing on current macOS |
| Native `GameController` recognition | **Not guaranteed**; macOS may ignore virtual controllers |
| DriverKit system extension | Design documented, not included as a claim of a signed/tested driver |
| Hardware verification | Still required on a Mac with real receivers/controllers |

### The important macOS limitation

The included backend uses `IOHIDUserDevice` because it supports the project's macOS 13 deployment target. On current macOS, creating a system virtual HID device normally requires the managed entitlement:

```text
com.apple.developer.hid.virtual.device
```

Putting that key in an entitlements plist does **not** grant it. Apple must authorize it for the signing identity/provisioning profile. Without that authorization, use `--no-hid` to verify receiver discovery and packet decoding.

Apple's newer CoreHID `HIDVirtualDevice` API is available on macOS 15+, but it has the same virtual-device policy problem. `GCVirtualController` is not a system-wide native-macOS solution: it is configured for controls inside the creating game and is documented for iOS, iPadOS, and Mac Catalyst.

An Apple Frameworks Engineer has also stated that macOS game-controller support contains checks that can ignore virtual HID devices. Consequently, this project publishes a **generic joystick identity**, rather than spoofing an Xbox VID/PID. That gives IOHID/SDL clients the best chance of using their generic HID path, but it cannot guarantee compatibility with every game or with System Settings > Game Controllers.

See [docs/RESEARCH.md](docs/RESEARCH.md) and [docs/DRIVERKIT_MIGRATION.md](docs/DRIVERKIT_MIGRATION.md).

## Receiver compatibility

Default accepted IDs are based on the current Linux `xpad` driver:

| VID:PID | Description in `xpad` | Default |
|---|---|---|
| `045e:0291` | Xbox 360 Wireless Receiver (XBOX) | Yes |
| `045e:02a9` | Xbox 360 Wireless Receiver (Unofficial) | Yes |
| `045e:0719` | Xbox 360 Wireless Receiver | Yes |

A third-party receiver with another ID may still work when it exposes interrupt IN and OUT endpoints on interfaces with:

```text
class 0xff, subclass 0x5d, protocol 0x81
```

Use an exact ID before using the broad override:

```sh
x360receiverbridge --usb-id abcd:1234 --no-hid --dump-state
```

`--allow-unknown` accepts any USB device with a matching interface signature. It is intended only for diagnosis because claiming the wrong vendor-specific interface can disrupt that device until the bridge exits.

This project targets the **Xbox 360 receiver protocol**, not the Xbox One/Series Wireless Adapter protocol.

## Build on macOS

### Requirements

- macOS 13 or later (project deployment target)
- Xcode Command Line Tools or Xcode
- CMake 3.22+
- C++17 compiler
- `libusb-1.0`
- `pkg-config`

With Homebrew:

```sh
brew install cmake ninja pkg-config libusb
```

### Build the decoder and app bundle

```sh
cd X360ReceiverBridge

cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
```

The executable is inside the generated bundle:

```sh
APP="build/x360receiverbridge.app/Contents/MacOS/x360receiverbridge"
"$APP" --help
"$APP" --list
```

The included helper performs the same build:

```sh
./scripts/build-macos.sh
```

#### Ninja repeatedly re-runs CMake

If Ninja reports `manifest 'build.ninja' still dirty after 100 tries`, the
extracted archive probably contains source timestamps later than the Mac's
clock. Version 0.1.1 and later detect and normalize this automatically. For an
older extraction, run:

```sh
rm -rf build
find . -type f -exec touch {} +
./scripts/build-macos.sh
```

#### Homebrew or Command Line Tools header errors

Version 0.1.2 fixes two build failures seen with Homebrew `libusb` and some
recent Command Line Tools SDKs:

```text
fatal error: 'libusb-1.0/libusb.h' file not found
fatal error: 'IOKit/hid/IOHIDUserDevice.h' file not found
```

The receiver now includes `libusb.h` through the include directory reported by
`pkg-config`. For `IOHIDUserDevice`, the backend no longer includes the missing
header; it loads the documented functions from Apple's linked IOKit framework
at runtime. The runtime entitlement requirement is unchanged.

After replacing an older source tree, always remove its CMake cache:

```sh
rm -rf build
./scripts/build-macos.sh
```

### First test: receiver and decoder only

Start without virtual HID output:

```sh
"$APP" --list
"$APP" --no-hid --dump-state
```

Then:

1. Press the sync button on the receiver.
2. Press the sync button on the Xbox 360 controller.
3. Move the sticks and press buttons.
4. Confirm decoded state changes appear in Terminal.
5. Press `Control-C` to exit.

Useful diagnostics:

```sh
./scripts/inspect-usb.sh
"$APP" --no-hid --dump-raw
"$APP" --usb-id 045e:02a9 --no-hid --dump-state
```

### Virtual HID build/signing

Generate an Xcode project so signing settings can be managed in Xcode:

```sh
cmake -S . -B build-xcode -G Xcode \
  -DX360BRIDGE_BUNDLE_IDENTIFIER=com.example.X360ReceiverBridge
open build-xcode/X360ReceiverBridge.xcodeproj
```

In Xcode, select your development team and a provisioning profile that actually contains `com.apple.developer.hid.virtual.device`. The checked-in file at `entitlements/X360ReceiverBridge.entitlements` only declares what the executable requests.

After a correctly entitled build, run:

```sh
APP="build-xcode/Release/x360receiverbridge.app/Contents/MacOS/x360receiverbridge"
"$APP" --dump-state
```

Depending on the macOS version and signing context, the system may also request user approval related to input control. Do not bypass macOS security controls. If the managed entitlement is not available, the supported diagnostic path is `--no-hid`.

## Command line

```text
--list                    list protocol-compatible receivers
--receiver-index N        choose receiver from --list (default 0)
--usb-id VID:PID          accept one explicit receiver USB ID
--allow-unknown           accept any FF/5D/81 protocol match
--no-hid                  decode only; do not create virtual HID
--dump-state              print decoded state changes
--dump-raw                print every USB packet
--deadzone N              per-axis square deadzone, 0..32767
--no-invert-y             preserve receiver Y-axis signs
--gamepad-usage           use HID Game Pad usage instead of Joystick
--virtual-vid HEX         override prototype virtual HID VID
--virtual-pid HEX         override prototype virtual HID PID
--led SLOT:MODE           send an Xbox LED mode, slot 1..4
--power-off SLOT          turn off the controller in a slot
--rumble S:L:R[:MS]       one-shot motor test, values 0..255
```

Examples:

```sh
# Decode a common clone receiver, no virtual device.
"$APP" --usb-id 045e:02a9 --no-hid --dump-state

# Apply a modest square stick deadzone.
"$APP" --deadzone 6000 --dump-state

# Test both motors on slot 1 for 750 ms, then exit.
"$APP" --no-hid --rumble 1:180:90:750

# Turn off the controller paired to slot 1, then exit.
"$APP" --no-hid --power-off 1

# Try the HID Game Pad usage rather than generic Joystick.
"$APP" --gamepad-usage
```

The default virtual identity `1209:0360` is a **prototype value, not an assigned product identity**. Before distributing a real product, obtain an appropriate VID/PID and pass it with `--virtual-vid` and `--virtual-pid` or change the defaults.

## Application compatibility

The generated device is a standards-based HID joystick containing:

- 16 button bits (11 currently assigned);
- one 8-way hat switch plus neutral;
- X/Y and Rx/Ry signed 16-bit axes;
- separate 8-bit brake/accelerator trigger axes.

Likely first test targets are SDL's controller test, Dolphin, OpenEmu, PCSX2, browser Gamepad API tests, and games that enumerate generic IOHID joysticks. Manual button mapping may be required.

Do not use appearance in System Settings > Game Controllers as the sole pass/fail test. A virtual device can be visible to IOHID/SDL while being omitted or rejected by the higher-level GameController framework.

## Known limitations

- The macOS virtual-HID backend is syntax-checked in CI-style validation, but still requires hardware testing and has not been exercised with an Apple-approved entitlement.
- No physical receiver/controller was available for this build, so USB behavior still needs macOS hardware testing.
- macOS GameController recognition is not guaranteed.
- Rumble is currently a command-line hardware test; game-originated HID force-feedback output reports are not implemented.
- Battery level, controller headset audio, chatpad input, and microphone support are not implemented.
- Receiver hot-plug/re-open is not implemented; restart the process after reconnecting a receiver.
- Unknown clones can differ electrically or in firmware even when their descriptors look compatible.
- The project does not install a launch daemon, menu-bar UI, package, auto-updater, or notarized binary.

## Source layout

```text
include/x360bridge/protocol.hpp       receiver packet/state model
include/x360bridge/receiver.hpp       libusb receiver API
include/x360bridge/hid_report.hpp     generic HID descriptor/report API
include/x360bridge/virtual_gamepad.hpp platform virtual-device API
src/protocol.cpp                      wireless packet decoder and commands
src/receiver.cpp                      discovery, claims, reads, writes
src/hid_report.cpp                    HID descriptor and report builder
src/virtual_gamepad_macos.mm          IOHIDUserDevice backend
src/main.cpp                          CLI and per-slot bridge
src/virtual_gamepad_stub.cpp          non-macOS diagnostic build stub
tests/protocol_tests.cpp              protocol and HID unit tests
docs/                                 research, architecture, migration, tests
```

## Safety and legacy-driver note

Remove or unload an old 360Controller installation using that project's documented uninstaller before testing, because a legacy kext may already own the receiver interfaces. This project intentionally provides no instructions for disabling SIP, reducing boot security, disabling AMFI, or loading an obsolete kernel extension. See [SECURITY.md](SECURITY.md).

## License and acknowledgements

The project is licensed under GPL-2.0. The protocol implementation was informed by the GPL-licensed Linux `xpad` driver and by historical macOS Xbox-controller projects; it is an independent, small implementation rather than a copied driver port. See [NOTICE.md](NOTICE.md) and [docs/RESEARCH.md](docs/RESEARCH.md).
