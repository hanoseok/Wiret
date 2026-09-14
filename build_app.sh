#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1

BIN="$(swift build -c release --show-bin-path)/Wiret"
APP="build/Wiret.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Wiret"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

codesign --force --sign - "$APP"

echo "Built: $APP"
