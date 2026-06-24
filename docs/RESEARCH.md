# Research notes

Research reviewed on **2026-06-24**. This document separates three questions that are often conflated:

1. Can macOS read an Xbox 360 USB wireless receiver?
2. Can software create a system-wide gamepad-like HID device?
3. Will every Mac game accept that virtual device through Apple's GameController framework?

The answers are, respectively: **yes in principle**, **yes with restricted platform authorization**, and **not reliably guaranteed**.

## Current Mac controller support

Apple's current support pages list these Xbox models for Apple devices including Mac:

- Xbox Wireless Controller with Bluetooth, Model 1708;
- Xbox Wireless Controller Series S and Series X;
- Xbox Elite Wireless Controller Series 2;
- Xbox Adaptive Controller.

Apple separately lists DualShock 4, DualSense, and DualSense Edge, and broadly supports compatible Xbox, PlayStation, and other Bluetooth controllers. macOS Ventura 13 and later includes a Game Controllers settings pane for controllers for which customization is available.

The published Xbox list does not include the pre-Bluetooth Xbox 360 wireless controller plus PC receiver. That is the gap this project targets. This should not be generalized to every Xbox 360 connection mode: SDL maintainers reported that macOS Sequoia added native handling for some *wired* Xbox 360 controllers through GameController.

Sources:

- https://support.apple.com/en-us/111101
- https://support.apple.com/en-us/111100
- https://support.apple.com/en-us/111099
- https://support.apple.com/guide/games/connect-a-game-controller-devf8cec167c/mac
- https://github.com/libsdl-org/SDL/issues/11002

## macOS API options

### GameController framework

`GCController` is the high-level consumer API used by games. It provides semantic controller profiles, discovery, button elements, motion, haptics, and system integration. It is the ideal endpoint for a physical supported controller, but it is not a public API for registering an arbitrary system-wide controller.

`GCVirtualController` is easy to misinterpret. Apple describes it as software emulation configured specifically for *your game*. Its documented availability is iOS 15+, iPadOS 15+, and Mac Catalyst 15+, not native macOS as a general system device. It is therefore not the bridge needed here.

Source:

- https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller

### IOHIDManager / IOHIDDevice

IOHIDManager and related IOKit APIs enumerate and consume HID devices. They are useful for reading ordinary HID controllers but do not make the Xbox 360 wireless receiver a standard gamepad: the receiver exposes a vendor-specific USB protocol and requires packet decoding.

### IOHIDUserDevice

`IOHIDUserDevice` is the long-standing user-space virtual HID mechanism. The project uses it because the deployment target is macOS 13. A process supplies a HID report descriptor and publishes input reports.

Modern macOS restricts virtual HID creation with the managed entitlement `com.apple.developer.hid.virtual.device`. A local entitlements plist is not sufficient; the capability must be present in the signed provisioning profile.

Apple's current API surface includes dispatch-queue lifecycle calls such as `IOHIDUserDeviceSetDispatchQueue`, `IOHIDUserDeviceSetCancelHandler`, `IOHIDUserDeviceActivate`, and `IOHIDUserDeviceCancel`, which the backend follows.

Sources:

- https://developer.apple.com/documentation/iokit/3334949-iohiduserdeviceactivate
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device

### CoreHID HIDVirtualDevice

CoreHID is Apple's modern Swift-concurrency HID framework. `HIDVirtualDevice` is available on macOS 15+ and can emulate a HID device, dispatch input reports, and receive report requests. It still requires the virtual-device entitlement, so moving this prototype from `IOHIDUserDevice` to CoreHID would modernize the code but would not remove the distribution constraint.

Sources:

- https://developer.apple.com/documentation/corehid
- https://developer.apple.com/documentation/corehid/hidvirtualdevice
- https://developer.apple.com/documentation/corehid/creatingvirtualdevices

### DriverKit, USBDriverKit, and HIDDriverKit

DriverKit moves many drivers out of the kernel and packages them as app extensions/system extensions. A production-grade receiver driver can use USBDriverKit to match the receiver's USB interfaces and HIDDriverKit to publish controller-facing HID services.

This is the strongest long-term architecture because the USB ownership and HID publication are handled in Apple's driver model rather than by a foreground CLI. It is also significantly heavier: DriverKit development and the device/family entitlements must be requested from Apple, the extension must be signed and activated, and real hardware debugging is essential.

Sources:

- https://developer.apple.com/documentation/driverkit
- https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development
- https://developer.apple.com/documentation/usbdriverkit
- https://developer.apple.com/documentation/usbdriverkit/iousbhostinterface
- https://developer.apple.com/documentation/hiddriverkit

## The virtual-gamepad compatibility problem

An accepted answer from an Apple Frameworks Engineer in January 2026 says that DriverKit or `IOHIDUserDevice` can technically fake a game controller, but that macOS game-controller support is designed for physical devices and contains checks to ignore virtual HID devices. Apple does not promise that this behavior will remain compatible.

Source:

- https://developer.apple.com/forums/thread/812774

This creates two observable layers:

1. **Generic IOHID layer.** An application may enumerate the HID joystick directly and receive reports.
2. **GameController layer.** macOS may choose not to promote the virtual HID service to a `GCController`.

SDL on macOS can use either Apple's GameController path or a generic IOHID path. Existing virtual-gamepad experiments report better compatibility when using a generic VID/PID and Joystick usage, rather than impersonating a recognized Xbox or PlayStation identity that SDL routes to GameController. That is why this prototype defaults to Generic Desktop / Joystick and a non-Xbox identity.

This is an engineering heuristic, not an Apple guarantee. A May 2026 SDL issue also reports a virtual `IOHIDUserDevice` working for input in an SDL application while force feedback varied by SDL version, reinforcing the need to test input and output independently.

Sources used as implementation evidence, not platform guarantees:

- https://github.com/trollzem/Lumen
- https://github.com/libsdl-org/SDL/issues/15663

## Receiver protocol research

The upstream Linux `xpad` driver is the most useful maintained public reference for the Xbox 360 receiver protocol. It identifies:

- `045e:0291` — Xbox 360 Wireless Receiver (XBOX)
- `045e:02a9` — Xbox 360 Wireless Receiver (Unofficial)
- `045e:0719` — Xbox 360 Wireless Receiver

It documents Xbox 360 wireless interfaces as vendor-specific protocol 129 (`0x81`) and decodes wireless input by stripping the receiver envelope before applying the normal Xbox 360 report mapping.

The USB interface signature used by known receivers is:

```text
bInterfaceClass    0xff
bInterfaceSubClass 0x5d
bInterfaceProtocol 0x81
```

The receiver presents a controller interface per wireless slot. Presence packets report connect/disconnect state, and valid input packets contain a wired-style Xbox 360 state report beginning at receiver byte 4. The project reads the fields needed through byte 17, even though receivers commonly transfer a 29-byte buffer.

Source:

- https://github.com/torvalds/linux/blob/master/drivers/input/joystick/xpad.c

## Older macOS projects

### 360Controller / TattieBogle lineage

The best-known historical project is `360Controller/360Controller`, a kernel-extension driver descended from TattieBogle. Its README states:

- wireless Xbox 360 support caused kernel panics from macOS 10.11 and was disabled in release 0.16.6;
- fixing it required a rewrite rather than a minor patch;
- there were no plans for Big Sur or Apple Silicon support as of December 2020.

This validates the decision not to revive or patch the old kext.

Source:

- https://github.com/360Controller/360Controller

### Experimental DriverKit port

`noah-nuebling/mac-gamepad-driver` attempted to port the old driver to modern DriverKit. Its associated issue describes it as incomplete and focused on wired-controller testing. It is valuable as a record of the entitlement and migration difficulty, but it is not a finished wireless receiver solution.

Sources:

- https://github.com/360Controller/360Controller/issues/1267
- https://github.com/noah-nuebling/mac-gamepad-driver

### Virtual HID examples

`Karabiner-DriverKit-VirtualHIDDevice` is a maintained example of a signed DriverKit virtual keyboard/mouse architecture. It does not implement a gamepad, but it demonstrates the host-app/system-extension/client shape and proves that DriverKit virtual HID is practical when the required entitlements are available.

`SillyUtility/VirtualController` is a game-controller-focused DriverKit experiment that reports compatibility with generic HID consumers such as OpenEmu. It is useful as an architectural reference, not as receiver protocol code.

Sources:

- https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice
- https://github.com/SillyUtility/VirtualController

## Chosen design

The proof-of-concept deliberately splits the problem:

- **Receiver core:** portable C++17 + libusb, with no kernel code.
- **Protocol core:** independently testable pure C++.
- **Virtual output:** small macOS Objective-C++ adapter around `IOHIDUserDevice`.
- **Future production path:** reuse the protocol/HID core in a DriverKit extension.

This lets hardware owners validate the difficult receiver packet path immediately with `--no-hid`, even before obtaining Apple virtual-HID authorization.

## What would falsify the approach

The project should be considered unsuccessful on a particular setup if any of these hold after debugging:

- libusb cannot claim any `FF/5D/81` receiver interface because macOS or another driver owns it;
- a clone uses a different wire protocol despite a similar descriptor;
- the virtual-HID entitlement is not approved for the project;
- target games exclusively use GameController and macOS filters the virtual service;
- a real receiver needs initialization behavior not represented in the current command set.

Those are separable failure modes. The testing guide records each layer independently so a GameController failure is not mistaken for a USB/protocol failure.
