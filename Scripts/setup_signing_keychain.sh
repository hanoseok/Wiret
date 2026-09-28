#!/usr/bin/env bash
# 서명 인증서(.p12)를 임시 키체인에 넣고, build_app.sh 가 쓸 SIGN_IDENTITY·SIGN_KEYCHAIN 을 알려 준다.
#
# 입력(환경 변수)
#   WIRET_SIGNING_P12_BASE64   : base64 로 인코딩한 .p12
#   WIRET_SIGNING_P12_PASSWORD : .p12 비밀번호
# 인자
#   $1 : 키체인을 만들 디렉터리 (기본: $RUNNER_TEMP, 없으면 임시 디렉터리)
#
# GitHub Actions 에서는 결과를 $GITHUB_ENV 에 쓰고, 그 밖에서는 export 문을 출력한다.
# 사용자 키체인 검색 목록을 바꾸므로 CI 처럼 매번 버려지는 환경에서 쓴다.
#
# 같은 인증서로 서명해야 macOS 가 업데이트 전후의 앱을 같은 앱으로 본다. ad-hoc 서명은
# 빌드마다 바뀌는 해시로 앱을 식별해서, 업데이트할 때마다 캘린더·마이크 권한이 초기화된다.
set -euo pipefail

: "${WIRET_SIGNING_P12_BASE64:?WIRET_SIGNING_P12_BASE64 가 필요합니다}"
: "${WIRET_SIGNING_P12_PASSWORD:?WIRET_SIGNING_P12_PASSWORD 가 필요합니다}"

WORK="${1:-${RUNNER_TEMP:-$(mktemp -d)}}"
KEYCHAIN="$WORK/wiret-signing.keychain-db"
P12="$WORK/wiret-signing.p12"
# 키체인 비밀번호는 이 실행 안에서만 쓰므로 매번 새로 만든다.
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"

printf '%s' "$WIRET_SIGNING_P12_BASE64" | base64 --decode > "$P12"
trap 'rm -f "$P12"' EXIT

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# 긴 빌드 도중 잠기지 않게 한다.
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$WIRET_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# 이게 없으면 codesign 이 키에 접근할 때 허용 창을 띄우려다 CI 에서 멈춘다.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# 자체 서명 인증서는 신뢰되지 않은 상태라, 키체인이 검색 목록에 없으면 codesign --keychain 으로
# 지정해도 "no identity found" 가 난다. 기존 목록 앞에 붙인다. (CI 러너는 매번 새로 만들어진다)
EXISTING=()
while IFS= read -r line; do
  line="${line//\"/}"
  line="${line#"${line%%[![:space:]]*}"}"
  [[ -n "$line" ]] && EXISTING+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" ${EXISTING[@]+"${EXISTING[@]}"}

# 이름은 겹칠 수 있으므로 SHA-1 로 정확히 지정한다.
IDENTITY="$(security find-certificate -a -Z "$KEYCHAIN" | awk '/SHA-1 hash:/ { print $3; exit }')"
if [[ -z "$IDENTITY" ]]; then
  echo "키체인에서 서명 인증서를 찾지 못했습니다" >&2
  exit 1
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "SIGN_IDENTITY=$IDENTITY"
    echo "SIGN_KEYCHAIN=$KEYCHAIN"
  } >> "$GITHUB_ENV"
  echo "서명 인증서 준비 완료: $IDENTITY"
else
  echo "export SIGN_IDENTITY=$IDENTITY"
  echo "export SIGN_KEYCHAIN=$KEYCHAIN"
fi
