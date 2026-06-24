# DriverKit migration plan

The current executable is intentionally a user-space proof-of-concept. A production release should evaluate a DriverKit system extension after the receiver and HID mapping are verified on hardware.

## Why migrate

DriverKit can provide:

- explicit ownership of the receiver interfaces;
- managed activation and lifecycle independent of a Terminal process;
- asynchronous USB I/O integrated with Apple's driver model;
- physical-driver-style HID publication;
- cleaner installation and logging boundaries.

It does **not** automatically solve GameController filtering. Apple has stated that the higher-level controller stack may ignore virtual HID devices, so a DriverKit build must still be tested with both IOHID clients and GameController clients.

## Proposed package layout

```text
X360ReceiverBridge.app
  ├─ settings / diagnostics UI
  ├─ system-extension activation code
  ├─ receiver status and logs
  └─ client connection to the DEXT

X360ReceiverBridge.dext
  ├─ USB receiver provider / interface ownership
  ├─ interrupt transfer pipeline
  ├─ shared packet decoder
  ├─ per-slot HID service/device objects
  └─ output report to receiver command translation
```

## USB matching

Start with narrow matching for the known receiver identities and controller interface protocol:

```text
VID:PID 045e:0291, 045e:02a9, 045e:0719
interface class/subclass/protocol ff/5d/81
```

Do not ship a wildcard vendor-specific match. Support for another clone should be added after capturing its descriptors and traffic.

A receiver exposes multiple interfaces. Driver matching must ensure the extension either binds the appropriate controller interfaces independently or coordinates them through a device-level service without claiming unrelated headset/security interfaces.

## Reusable code

These files are designed to move into the extension with minimal changes:

- `protocol.hpp/.cpp`
- `hid_report.hpp/.cpp`

`receiver.cpp` is libusb-specific and should be replaced by USBDriverKit transfer objects. `virtual_gamepad_macos.mm` is replaced by HIDDriverKit device/service code.

## Transfer pipeline

Recommended design:

1. Open the selected `IOUSBHostInterface`.
2. Locate interrupt IN/OUT pipes from its descriptors.
3. Allocate fixed-size `IOBufferMemoryDescriptor` objects.
4. Submit one asynchronous interrupt read per slot.
5. On completion, validate length and call the shared decoder.
6. Resubmit immediately unless stopping or detached.
7. Serialize writes per interface for presence, LED, rumble, and power-off commands.
8. On termination, cancel transfers before closing pipes/interfaces.

Keep packet parsing outside completion callbacks where possible. A small per-slot serial dispatch queue makes ordering and teardown easier to reason about.

## HID publication

A per-slot HID device/service should expose the descriptor from `make_hid_report_descriptor()` and forward normalized input reports from `make_hid_input_report()`.

The exact DriverKit class hierarchy must be selected and validated against the SDK used for the implementation. Relevant frameworks/classes include:

- DriverKit `IOService` lifecycle;
- USBDriverKit `IOUSBHostInterface` and host pipes;
- HIDDriverKit `IOHIDDevice` / user HID device or event-service subclasses;
- `handleReport`/report completion APIs for publishing data.

Do not hard-code the proof-of-concept VID/PID in a distributable DEXT.

## Output and rumble

The current HID descriptor is input-only. For game-originated rumble, define a deliberate output/feature report format and implement the corresponding HIDDriverKit report callback. Translate validated motor values to `make_rumble_command()`.

This must be tested across target applications because SDL/GameController force-feedback paths can differ from their input paths.

## Entitlements and signing

Expect to request and provision, as applicable:

- DriverKit development/system-extension capability;
- USB transport access narrowed to the receiver VID/PID/interface;
- HIDDriverKit family/device capabilities;
- virtual HID device capability if the chosen publication model requires it.

Apple's current documentation requires developers to request DriverKit entitlements and any additional family/transport entitlements needed for the hardware. Exact entitlement keys and provisioning requirements should be taken from the current Xcode SDK and Apple Developer portal at implementation time.

References:

- https://developer.apple.com/documentation/driverkit
- https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development
- https://developer.apple.com/documentation/usbdriverkit
- https://developer.apple.com/documentation/hiddriverkit
- https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice

## Activation and update flow

The host app should use `OSSystemExtensionManager` to request activation. Plan for:

- explicit user approval;
- versioned replacement;
- activation/reboot diagnostics;
- uninstall/deactivation;
- structured unified logging;
- restoration after receiver detach/attach.

Do not build operational instructions around `systemextensionsctl` reset, disabled SIP, reduced security, or AMFI changes. Those are debugging escape hatches, not an acceptable product architecture.

## Hardware validation gates

Do not declare the DriverKit port production-ready until all of these pass:

1. Intel and Apple silicon Macs on supported macOS versions.
2. `045e:0719`, `045e:0291`, and at least one `045e:02a9` clone.
3. One through four simultaneously connected controllers.
4. Controller connect/disconnect while the receiver remains attached.
5. Receiver unplug during active reads and writes.
6. Sleep/wake and user logout/login.
7. Input in a direct IOHID test, SDL, at least two emulators, and native GameController clients.
8. Output rumble in every supported client path.
9. Extension update and uninstall without orphaned services.
