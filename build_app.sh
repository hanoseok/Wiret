#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# 옵션(환경 변수)
#   UNIVERSAL=1            : arm64 + x86_64 유니버설 바이너리로 빌드
#   MARKETING_VERSION=x.y.z: CFBundleShortVersionString 값 덮어쓰기
#   BUILD_NUMBER=n         : CFBundleVersion 값 덮어쓰기
BUILD_ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}" 2>&1

BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Wiret"
APP="build/Wiret.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Wiret"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

PLIST="$APP/Contents/Info.plist"
if [[ -n "${MARKETING_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$PLIST"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

# Info.plist 수정 후에 서명해야 서명이 깨지지 않는다
codesign --force --sign - "$APP"

echo "Built: $APP"
