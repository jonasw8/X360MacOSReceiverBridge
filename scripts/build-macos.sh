#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
GENERATOR="${GENERATOR:-Ninja}"
BUILD_TYPE="${BUILD_TYPE:-Release}"

# ZIP timestamps do not contain a timezone. An archive created in UTC and
# extracted west of UTC can therefore produce source files several hours in
# the future. Ninja then keeps regenerating build.ninja until it gives up.
# Normalize only future-dated project files, leaving ordinary incremental
# build timestamps untouched.
CLOCK_STAMP="$(mktemp "${TMPDIR:-/tmp}/x360receiverbridge-clock.XXXXXX")"
FUTURE_LIST="$(mktemp "${TMPDIR:-/tmp}/x360receiverbridge-future.XXXXXX")"
cleanup_clock_files() {
    rm -f "$CLOCK_STAMP" "$FUTURE_LIST"
}
trap cleanup_clock_files EXIT

touch "$CLOCK_STAMP"
find "$ROOT" \
    -path "$BUILD_DIR" -prune -o \
    -type f -newer "$CLOCK_STAMP" -print > "$FUTURE_LIST"
if [[ -s "$FUTURE_LIST" ]]; then
    echo "Normalizing future-dated source timestamps:" >&2
    while IFS= read -r source_file; do
        echo "  ${source_file#$ROOT/}" >&2
        touch "$source_file"
    done < "$FUTURE_LIST"
fi

for tool in cmake pkg-config; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool" >&2
        exit 1
    fi
done

if ! pkg-config --exists libusb-1.0; then
    echo "libusb-1.0 was not found by pkg-config." >&2
    echo "With Homebrew: brew install pkg-config libusb" >&2
    exit 1
fi

cmake -S "$ROOT" -B "$BUILD_DIR" -G "$GENERATOR" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
cmake --build "$BUILD_DIR"
ctest --test-dir "$BUILD_DIR" --output-on-failure

APP_BUNDLE="$BUILD_DIR/X360 Controller Bridge.app"
APP="$APP_BUNDLE/Contents/MacOS/X360 Controller Bridge"
if [[ -x "$APP" ]]; then
    echo
    echo "Built: $APP_BUNDLE"
    echo "Launch: open '$APP_BUNDLE'"
    echo "CLI:    '$APP' --help"
else
    echo "Build completed, but the expected app executable was not found: $APP" >&2
    exit 1
fi
