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

The project will not treat weakening those protections as a normal installation step. The app includes a compatibility mode for local development on SIP/AMFI-disabled Macs, but that mode is intentionally labeled as development-only. A polished public virtual-HID build must use Apple-approved signing/entitlements or leave virtual output disabled.

## USB-device safety

By default, only established Xbox 360 receiver IDs and the official wired Xbox 360 controller ID are eligible. A wireless receiver must expose the expected `FF/5D/81` controller interface with interrupt IN and OUT endpoints. A wired controller must expose the expected wired controller interface and input packet shape.

`--usb-id`, `--allow-unknown`, and the app's compatibility/protocol-match settings weaken identity filtering. Use them only after examining the device descriptors. The bridge caps matching wireless interfaces at four and only issues small controller/receiver commands, but claiming an unrelated interface can still interrupt another device until the process exits.

## Data handling

The bridge does not use a network connection or write controller input to disk. `--dump-raw` and the app's advanced raw logging setting print USB packets to the terminal/backend log. Treat diagnostic logs as potentially sensitive because button timing can reveal user behavior.

## Reporting vulnerabilities

Include:

- the commit/version;
- macOS and architecture;
- receiver VID:PID and descriptors;
- a minimal reproduction;
- sanitizer/crash output;
- whether `--allow-unknown` was used.

Do not include secrets, signing certificates, provisioning profiles, or private controller-use logs.
