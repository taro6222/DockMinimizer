#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 changhun
# .app 번들을 조립하고 서명한다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_NAME="${DOCKMINIMIZER_CERT:-DockMinimizer Self Signed}"
APP="$ROOT/build/DockMinimizer.app"

echo "==> 릴리스 빌드"
swift build -c release --package-path "$ROOT" --product DockMinimizer
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

echo "==> 번들 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DockMinimizer" "$APP/Contents/MacOS/DockMinimizer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "==> 서명: $CERT_NAME"
    codesign --force --sign "$CERT_NAME" "$APP"
else
    echo "경고: '$CERT_NAME' 인증서가 없습니다. Scripts/make-cert.sh 를 먼저 실행하세요."
    echo "      임시로 ad-hoc 서명합니다. 재빌드 때마다 접근성 권한이 사라집니다."
    codesign --force --sign - "$APP"
fi

codesign --verify --verbose=2 "$APP"
echo "==> 완료: $APP"
