#!/bin/bash
# Builds Grabby.app into ./build with libusb embedded and an ad-hoc signature.
#
#   scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Grabby.app"

cd "$ROOT"
swift build -c "$CONFIG" --product Grabby
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Grabby"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Grabby"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Ship libusb inside the bundle so the app runs without Homebrew.
LIBUSB="$(otool -L "$BIN" | awk '/libusb-1.0/ {print $1}')"
cp -L "$LIBUSB" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
chmod u+w "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -change "$LIBUSB" @rpath/libusb-1.0.0.dylib "$APP/Contents/MacOS/Grabby"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Grabby"

codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - "$APP"

echo "Built $APP"
