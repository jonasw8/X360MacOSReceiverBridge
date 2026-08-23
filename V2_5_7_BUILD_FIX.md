# v2.5.7 build fix

Fixes the v2.5.6 Objective-C++ build error where one batterySummary() call
still passed only three arguments after the function gained batteryPidCount.

No battery research logic, input mapping, rumble, Power Off, or HID profile
behavior was changed.
