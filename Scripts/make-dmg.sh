#!/usr/bin/env bash
# 드래그 설치용 DMG를 만든다. 외부 의존성 없이 hdiutil만 사용한다.
#
# 결과물은 자체 서명이므로 다른 Mac에서는 Gatekeeper가 막는다.
# DMG 안의 안내 파일과 README에 우회 방법을 적어 둔다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_NAME="${DOCKMINIMIZER_CERT:-DockMinimizer Self Signed}"
APP="$ROOT/build/DockMinimizer.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/build/DockMinimizer-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; hdiutil detach "/Volumes/DockMinimizer" -quiet 2>/dev/null || true' EXIT

echo "==> 앱 빌드 및 서명"
"$ROOT/Scripts/bundle.sh"

echo "==> DMG 내용 구성"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/먼저 읽어주세요.txt" <<'NOTE'
DockMinimizer 설치 안내
=======================

활성 상태인 앱의 Dock 아이콘을 클릭하면 그 앱의 윈도우를 최소화합니다.
한 번 더 클릭하면 복원됩니다.


1. 설치
-------
DockMinimizer.app 을 옆의 Applications 폴더로 끌어다 놓으세요.


2. 처음 실행 (중요)
-------------------
이 앱은 자체 서명되어 있어 그냥 더블클릭하면 macOS가 실행을 막습니다.

  DockMinimizer.app 을 마우스 오른쪽 버튼으로 클릭 → "열기" → 다시 "열기"

한 번만 이렇게 하면 이후에는 그냥 실행됩니다.

그래도 열리지 않으면 터미널에서:

  xattr -dr com.apple.quarantine /Applications/DockMinimizer.app


3. 접근성 권한 부여 (필수)
--------------------------
시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용

  + 버튼 → /Applications/DockMinimizer.app 추가 → 토글 켜기

이 권한이 없으면 아무 동작도 하지 않습니다.
Dock 클릭을 감지하고 다른 앱의 윈도우를 최소화하는 데 필요합니다.

권한을 켰는데도 동작하지 않으면, 메뉴바 아이콘에
"권한 부여됨 — 재실행해야 적용됩니다" 가 표시됩니다. "재실행"을 누르세요.
macOS가 앱 시작 시점에 권한을 고정하기 때문입니다.


4. 사용
-------
메뉴바 오른쪽에 아이콘이 생깁니다. 여기서 켜기/끄기, 제외할 앱,
로그인 시 자동 시작을 설정할 수 있습니다.

Dock에는 이 앱의 아이콘이 생기지 않습니다 (메뉴바 전용 앱).


알아 두실 점
------------
- 활성 상태인 앱의 Dock 아이콘은 드래그로 위치를 바꿀 수 없습니다.
  그 클릭을 가로채야 최소화가 동작하기 때문입니다. 다른 아이콘은 영향 없습니다.
- Dock "확대" 기능이 켜져 있으면 오작동을 막기 위해 자동으로 일시 중지됩니다.
  메뉴바에 그 사유가 표시됩니다.
- 제거하려면 메뉴바에서 종료한 뒤 /Applications/DockMinimizer.app 을 삭제하고,
  손쉬운 사용 목록에서도 지우면 됩니다.
NOTE

echo "==> DMG 생성: $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "DockMinimizer" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG" >/dev/null

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "==> DMG 서명"
    codesign --force --sign "$CERT_NAME" "$DMG"
fi

echo "==> 검증"
hdiutil verify "$DMG" >/dev/null && echo "이미지 무결성 OK"
codesign --verify --verbose=2 "$DMG" 2>&1 | tail -2 || true

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "완료: $DMG  ($SIZE)"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
