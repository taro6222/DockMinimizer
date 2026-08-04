#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 changhun
# /Applications 고정 경로에 설치한다.
# 경로가 바뀌면 접근성 권한이 사라지므로 항상 같은 경로를 쓴다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/Applications/DockMinimizer.app"

"$ROOT/Scripts/bundle.sh"

echo "==> 실행 중인 인스턴스 종료"
pkill -x DockMinimizer 2>/dev/null || true
sleep 1

echo "==> 설치: $DEST"
rm -rf "$DEST"
cp -R "$ROOT/build/DockMinimizer.app" "$DEST"

echo "==> 실행"
open "$DEST"
echo "완료."
