#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# 옵션(환경 변수)
#   UNIVERSAL=1            : arm64 + x86_64 유니버설 바이너리로 빌드
#   WIRET_VERSION=x.y.z[-SNAPSHOT]
#                          : 배포 버전. WiretVersion 키에 그대로 기록하고 숫자 부분은
#                            CFBundleShortVersionString 으로 쓴다. 자동 업데이트는 이 키로
#                            자기 채널(스냅샷/정식)을 판단하므로, 없으면 로컬 빌드로 보고
#                            업데이트를 제안하지 않는다.
#   MARKETING_VERSION=x.y.z: CFBundleShortVersionString 만 덮어쓰기
#   BUILD_NUMBER=n         : CFBundleVersion 값 덮어쓰기
#   SIGN_IDENTITY=...      : 서명에 쓸 인증서(이름 또는 SHA-1). 없으면 ad-hoc(-) 서명.
#                            ad-hoc 서명은 빌드마다 바뀌는 해시로 앱을 식별하므로, 업데이트할
#                            때마다 캘린더·마이크 권한이 초기화된다. 같은 인증서로 서명하면
#                            식별 기준이 인증서가 되어 권한이 유지된다.
#   SIGN_KEYCHAIN=path     : SIGN_IDENTITY 를 찾을 키체인 (CI 의 임시 키체인)
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

# 앱 아이콘은 저장소에 바이너리로 두지 않고 MouseIcon.swift 에서 매번 생성한다.
ICONSET="$(mktemp -d)/Wiret.iconset"
cat Sources/Wiret/MouseIcon.swift Scripts/export_app_icon_main.swift | swift - "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

PLIST="$APP/Contents/Info.plist"
if [[ -n "${WIRET_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :WiretVersion string $WIRET_VERSION" "$PLIST"
  # CFBundleShortVersionString 은 숫자만 받으므로 -SNAPSHOT 을 떼고 넣는다.
  : "${MARKETING_VERSION:=${WIRET_VERSION%-SNAPSHOT}}"
fi
if [[ -n "${MARKETING_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$PLIST"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

# Info.plist 수정 후에 서명해야 서명이 깨지지 않는다
SIGN_ARGS=(--force --sign "${SIGN_IDENTITY:--}")
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
  SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
fi
codesign "${SIGN_ARGS[@]}" "$APP"

echo "Built: $APP"
