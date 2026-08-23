#!/bin/zsh
set -eu

echo "== system_profiler USB receiver candidates =="
system_profiler SPUSBDataType | grep -B 5 -A 15 -Ei 'Xbox|Wireless Receiver|Product ID: 0x(0291|02a9|0719)' || true

echo
echo "== IORegistry protocol-0x81 interface hints =="
ioreg -p IOUSB -l -w 0 | grep -Ei 'Xbox|Wireless Receiver|bInterfaceProtocol|bInterfaceSubClass|idVendor|idProduct' || true

echo
echo "After building, use: build/X360 Controller Bridge.app/Contents/MacOS/X360 Controller Bridge --list"
