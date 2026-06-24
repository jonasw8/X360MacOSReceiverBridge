# Security policy and operating model

## Supported security posture

X360ReceiverBridge is designed to run without:

- a kernel extension;
- disabled System Integrity Protection;
- disabled AMFI;
- reduced startup security;
- root privileges;
- a privileged daemon;
- undocumented patching of macOS binaries.

The project will not treat weakening those protections as an installation step. The virtual HID feature must use Apple-approved signing/entitlements or remain disabled with `--no-hid`.

## USB-device safety

By default, only three established receiver IDs are eligible, and a device must also expose the expected `FF/5D/81` controller interface with interrupt IN and OUT endpoints.

`--usb-id` and especially `--allow-unknown` weaken identity filtering. Use them only after examining the device descriptors. The bridge caps matching interfaces at four and only issues the documented small receiver commands, but claiming an unrelated interface can still interrupt another device until the process exits.

## Data handling

The bridge does not use a network connection or write controller input to disk. `--dump-raw` prints receiver packets to the terminal. Treat diagnostic logs as potentially sensitive because button timing can reveal user behavior.

## Reporting vulnerabilities

Include:

- the commit/version;
- macOS and architecture;
- receiver VID:PID and descriptors;
- a minimal reproduction;
- sanitizer/crash output;
- whether `--allow-unknown` was used.

Do not include secrets, signing certificates, provisioning profiles, or private controller-use logs.
