# Testing guide

Test the layers independently. A game not seeing the controller does not prove the receiver decoder is broken.

## 1. Unit tests

```sh
cmake -S . -B build-tests \
  -DX360BRIDGE_BUILD_APP=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-tests
ctest --test-dir build-tests --output-on-failure
```

Coverage includes:

- connection and disconnection status packets;
- full controller-state decoding;
- truncation and unknown-payload handling;
- button and axis mapping;
- D-pad/hat conversion;
- LED, presence, rumble, and power-off commands;
- deadzone behavior;
- HID descriptor/report construction.

## 2. USB discovery

```sh
./scripts/inspect-usb.sh
APP="build/x360receiverbridge.app/Contents/MacOS/x360receiverbridge"
"$APP" --list
```

Record:

- Mac model and architecture;
- exact macOS version/build;
- receiver markings;
- VID:PID;
- manufacturer/product strings;
- number of matched controller interfaces.

Expected common output includes four slots. Some descriptors or hub arrangements may differ, so save the complete `system_profiler SPUSBDataType` output when reporting a problem.

## 3. Raw packet capture

```sh
"$APP" --usb-id 045e:0719 --no-hid --dump-raw
```

Test this sequence:

1. Start with controller off.
2. Turn it on and pair.
3. Press each face/shoulder/stick button individually.
4. Press every D-pad direction and diagonal.
5. Sweep each stick to its limits.
6. Sweep each trigger from zero to full.
7. Disconnect by removing the battery pack.

Never publish a capture that contains unrelated USB device data. The bridge only dumps the selected receiver interfaces, but verify the selected VID:PID first.

## 4. Decoded state

```sh
"$APP" --no-hid --dump-state
```

Check:

- A/B/X/Y are not permuted;
- Back, Start, Guide, L3, R3, LB, and RB change independently;
- hat values move clockwise: N=0, NE=1, E=2, ... NW=7, neutral=8;
- triggers span approximately `0..255`;
- sticks span negative and positive 16-bit ranges;
- Y direction feels correct after the default inversion;
- connect and disconnect events refer to the right slot.

Repeat with two, three, and four controllers where possible.

## 5. Receiver commands

```sh
# Steady quadrant 1 on slot 1.
"$APP" --no-hid --led 1:6

# One-shot motor test.
"$APP" --no-hid --rumble 1:200:100:1000

# Turn off the controller in slot 1.
"$APP" --no-hid --power-off 1
```

The bridge automatically requests presence and assigns steady quadrant LED modes `6..9` when controllers connect.

## 6. Virtual HID creation

Only perform this with an executable signed using a profile that contains the managed virtual-HID entitlement.

```sh
codesign -d --entitlements :- \
  build/x360receiverbridge.app 2>&1

"$APP" --dump-state
```

Expected log:

```text
created virtual HID gamepad for slot 1
```

Inspect generic HID visibility:

```sh
ioreg -r -c IOHIDUserDevice -l
system_profiler SPUSBDataType
```

The device is virtual, so it may not appear under a physical USB tree. Use an IOHID inspection tool or an application that lists generic joysticks.

## 7. Client matrix

Record **input enumeration**, **button/axis input**, **manual mapping**, and **rumble** separately.

| Client category | Suggested test | Expected caveat |
|---|---|---|
| Direct IOHID | HID inspection/sample tool | Most direct validation |
| SDL | `testcontroller` / `testgamepad` from current SDL | May require mapping; backend choice matters |
| Browser | Gamepad API test page | Browser may apply its own allow-list/mapping |
| Emulator | Dolphin, OpenEmu, PCSX2 | Usually supports generic HID/SDL mapping |
| Steam | Controller settings / game | Steam Input behavior varies by release |
| Native GameController game | A current Mac game | May not enumerate virtual HID at all |
| System Settings | Game Controllers pane | Absence is not proof of IOHID failure |

## 8. Failure classification

### Receiver not listed

- Confirm VID:PID in `system_profiler`.
- Confirm an `FF/5D/81` interface exists.
- Remove old Xbox 360 kext software that may own it.
- Try a direct Mac port or powered hub.
- Use `--usb-id` only after checking the identity.

### Receiver opens but no state

- Pair after the bridge starts.
- Capture `--dump-raw`.
- Test presence query and LED command.
- Compare all interface endpoint descriptors.
- Check whether the clone needs an initialization packet not yet implemented.

### State logs but no virtual gamepad

- Check the entitlement embedded in the signed executable and provisioning profile.
- Read the explicit `virtual HID unavailable` error.
- Confirm user input-control approval if macOS requested it.

### Generic HID works but game does not

- Try SDL/direct IOHID tools.
- Try `--gamepad-usage` and manual mapping.
- Do not change to an Xbox VID/PID as the first fix; that can route the device into a GameController path that filters virtual devices.
- Treat the result as a client/GameController compatibility issue, not a receiver issue.

## Hardware report template

```text
Mac model/CPU:
macOS version/build:
Xcode/SDK version:
Receiver label and photo description:
VID:PID:
--list output:
Number of controllers:
Official or third-party controllers:
Decode-only result:
Virtual-HID signing/entitlement result:
IOHID/SDL result:
GameController/System Settings result:
Raw packet excerpt around failure:
```

## Build compatibility checks

A Homebrew installation normally reports an include directory ending in
`include/libusb-1.0`; source files should therefore include `libusb.h`, not add
that directory name a second time.

Some Command Line Tools SDK releases omit the standalone
`IOKit/hid/IOHIDUserDevice.h` file even though the documented symbols are part
of IOKit. The macOS backend therefore does not include that header; it resolves
the documented functions from the linked IOKit framework at runtime. Version
0.1.2 was syntax-checked with an SDK-shaped header set that intentionally omits
`IOHIDUserDevice.h`, in addition to the regular macOS CI configuration.
