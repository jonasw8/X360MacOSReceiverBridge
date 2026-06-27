#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_BUNDLE="$BUILD_DIR/X360 Controller Bridge.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/X360 Controller Bridge"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
ENTITLEMENTS="$ROOT/entitlements/X360ReceiverBridge.entitlements"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="$(awk '/^project\(X360ReceiverBridge VERSION / { print $3; exit }' "$ROOT/CMakeLists.txt")"
VERSION="${VERSION:-0.2.0}"
ARCHIVE="$DIST_DIR/X360-Controller-Bridge-${VERSION}-macOS.zip"

"$ROOT/scripts/build-macos.sh"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Expected app executable was not found: $EXECUTABLE" >&2
    exit 1
fi

mkdir -p "$FRAMEWORKS_DIR" "$DIST_DIR"

# Bundle Homebrew/MacPorts libusb so the Finder app does not depend on the
# developer's local package-manager paths.
LIBUSB_PATH="$(otool -L "$EXECUTABLE" | awk '/libusb-1\.0/ { print $1; exit }')"
if [[ -n "$LIBUSB_PATH" && "$LIBUSB_PATH" = /* && -f "$LIBUSB_PATH" ]]; then
    LIBUSB_NAME="$(basename "$LIBUSB_PATH")"
    cp -f "$LIBUSB_PATH" "$FRAMEWORKS_DIR/$LIBUSB_NAME"
    install_name_tool -id "@executable_path/../Frameworks/$LIBUSB_NAME" "$FRAMEWORKS_DIR/$LIBUSB_NAME" || true
    install_name_tool -change "$LIBUSB_PATH" "@executable_path/../Frameworks/$LIBUSB_NAME" "$EXECUTABLE"
    echo "Bundled: $LIBUSB_NAME"
fi

# Ad-hoc signing is useful for local SIP/AMFI-disabled development machines.
# Set CODESIGN_IDENTITY='Developer ID Application: ...' for a distribution build
# with a valid provisioning profile/entitlement grant.
if command -v codesign >/dev/null 2>&1; then
    for dylib in "$FRAMEWORKS_DIR"/*.dylib(N); do
        codesign --force --sign "$IDENTITY" "$dylib"
    done
    codesign --force --deep --options runtime --timestamp=none \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_BUNDLE"
fi

rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE"

echo
echo "Packaged: $ARCHIVE"
echo "For public distribution, re-sign with a Developer ID identity, notarize, and staple."
