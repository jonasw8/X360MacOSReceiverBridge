# Architecture

## Goals

- Read first-party and common third-party Xbox 360 wireless receivers without a kernel extension.
- Add official wired Xbox 360 USB controller support without changing the normalized state model.
- Keep all receiver/protocol logic independently testable.
- Present a native, consumer-facing macOS app while preserving the CLI diagnostics.
- Represent every connected wireless slot or wired controller as a separate gamepad-like device.
- Show a single native privacy row when Accessibility approval is missing and fail safely when virtual HID creation is unavailable.
- Preserve a clean migration boundary for CoreHID or DriverKit.

## Components

### `protocol`

Pure C++ transformations with no USB or macOS dependency:

- receiver packet to `WirelessEvent`;
- `State` normalization;
- D-pad to HID hat conversion;
- deadzone filtering;
- receiver presence, LED, rumble, and power-off command construction.

### `receiver`

A libusb service that:

1. enumerates USB devices;
2. filters by a known/exact VID:PID policy;
3. validates the interface signature `FF/5D/81`;
4. locates interrupt IN and OUT endpoints;
5. claims up to four controller interfaces;
6. starts one bounded-timeout read thread per interface;
7. emits `SlotEvent` callbacks;
8. serializes writes per slot.

The default policy requires a known ID. `--usb-id` admits exactly one specified identity. `--allow-unknown` broadens matching only after the descriptor signature has been verified.

### `wired_controller`

A libusb service for wired Xbox 360 USB controllers. It:

1. enumerates USB devices;
2. accepts the official Microsoft wired-controller ID by default;
3. can opt into protocol-matched third-party devices;
4. claims the controller interface with interrupt IN and OUT endpoints;
5. emits normalized `WiredControllerEvent` state callbacks;
6. supports a direct rumble-test command.

It shares the same `State` model as the wireless receiver path so the app and virtual HID backend do not need separate wired/wireless report code.

### `hid_report`

Creates a generic HID report descriptor and translates normalized controller state into a fixed input report.

#### Input report layout

All offsets are bytes; report size is 14 bytes.

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | Report ID `1` |
| 1 | 2 | 16 little-endian button bits |
| 3 | 1 | Low nibble: hat `0..7`, `8` neutral; high nibble padding |
| 4 | 2 | X / left stick X, signed little-endian |
| 6 | 2 | Y / left stick Y, signed little-endian |
| 8 | 2 | Rx / right stick X, signed little-endian |
| 10 | 2 | Ry / right stick Y, signed little-endian |
| 12 | 1 | Brake / left trigger, `0..255` |
| 13 | 1 | Accelerator / right trigger, `0..255` |

Button order:

```text
1 A       2 B       3 X       4 Y
5 LB      6 RB      7 Back    8 Start
9 L3     10 R3     11 Guide  12..16 reserved
```

The default descriptor uses Generic Desktop / Joystick. `--gamepad-usage` changes the top-level usage to Game Pad without changing the report layout.

### `virtual_gamepad_macos`

A narrow `IOHIDUserDevice` adapter:

- checks the user-visible Accessibility grant before attempting virtual-device creation;
- builds the property dictionary and report descriptor;
- assigns a unique location/serial per virtual controller;
- uses a serial dispatch queue;
- registers the cancellation handler before activation;
- sends a neutral report on creation and before teardown;
- waits briefly for asynchronous cancellation without double-releasing the device.

The adapter contains no receiver or wired-controller protocol logic. It can be replaced by CoreHID or DriverKit without changing packet parsing.

### `macos_app`

The native AppKit app owns the consumer workflow:

- main window with System Settings-style groups for bridge actions, privacy, receiver discovery, connected controllers, and status;
- menu-bar extra with start/stop scanning, connected-controller summaries, rumble, disconnect, settings, and quit;
- guided “Add Wireless Controller” and “Add Wired Controller” prompts;
- detail windows with native live-input rows;
- settings for scan-at-launch, menu-bar/background mode, raw logging, and SIP/AMFI-disabled development compatibility mode.

The app starts the wireless receiver and wired controller services, creates `VirtualGamepad` objects on first state, and updates UI state from USB callbacks on the main queue.

### `main` / `Bridge`

The CLI remains available when command-line flags are supplied. It owns one `Receiver` and up to four `VirtualGamepad` objects. A connected event creates the slot's virtual device and sets a steady quadrant LED. A disconnect event destroys only that slot. State events are filtered, optionally logged, and submitted to the matching virtual device.

## Thread model

```text
AppKit main thread
  ├─ main window, menu-bar extra, settings, detail windows
  ├─ privacy open/check actions
  └─ UI refresh from USB callbacks

scan timer / discovery queue
  ├─ Receiver::discover
  └─ WiredController::discover

receiver read thread 0 ─┐
receiver read thread 1 ─┼─ SlotEvent callback ─ mutex ─ per-slot state/device ─ main-queue UI refresh
receiver read thread 2 ─┤
receiver read thread 3 ─┘

wired read thread ─ WiredControllerEvent callback ─ mutex ─ wired state/device ─ main-queue UI refresh

per-controller HID dispatch queue
  └─ IOHIDUserDevice lifecycle/cancel callbacks

CLI mode uses the older single-threaded lifecycle loop when flags are passed to the app executable.
```

libusb interrupt reads use a 250 ms timeout. This permits a clean `Control-C` stop without asynchronous transfer cancellation complexity. Receiver writes have a 1 second timeout and a per-interface mutex.

## Disconnect and teardown behavior

- A USB `NO_DEVICE` result clears the shared running flag.
- `Receiver::stop()` always joins every joinable thread, even if a read thread already cleared that flag.
- Interfaces are explicitly released before the USB handle closes.
- Each HID device receives a neutral report before cancellation.
- The cancel handler owns the CoreFoundation create-rule reference, preventing release while callbacks may still be in flight.

## Trust boundaries

Receiver input is untrusted USB data. Defensive choices include:

- endpoint and interface validation before claims;
- a four-interface cap;
- length checks before every decoded field range;
- ignoring well-formed but unknown payload types;
- no dynamic allocation based on packet-supplied lengths;
- exact/known ID matching by default;
- compatibility/protocol matching only after an explicit user setting or CLI flag;
- no privileged helper, kext, or security-control modification as a normal install step.

## Why a generic HID identity

macOS can route known controller identities through GameController-specific backends. Because Apple says virtual devices can be filtered by GameController, impersonating a physical Xbox VID/PID may move the device onto a path that rejects it. A generic joystick identity leaves generic IOHID/SDL consumers able to inspect the report descriptor directly.

The built-in default VID/PID is only a prototype setting. Distribution requires a legitimate product identity.
