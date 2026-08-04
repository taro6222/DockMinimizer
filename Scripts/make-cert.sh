#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 changhun
# 재빌드해도 접근성 권한이 유지되도록 고정 self-signed 코드서명 인증서를 만든다.
# ad-hoc 서명(codesign -s -)은 빌드마다 cdhash가 바뀌어 TCC 권한이 사라진다.
set -euo pipefail

CERT_NAME="${DOCKMINIMIZER_CERT:-DockMinimizer Self Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "이미 존재합니다: $CERT_NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 자체 서명 인증서 생성"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

# 빈 암호로 내보내면 macOS security가 MAC 검증에 실패한다("wrong password?").
# 임시 암호를 쓴다. p12는 이 스크립트가 끝나면 지워진다.
P12_PASS="dockminimizer-import"
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CERT_NAME" -passout "pass:$P12_PASS"

echo "==> 키체인에 가져오기 (키체인 암호 입력창이 뜰 수 있습니다)"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security

echo "==> 코드서명 신뢰 설정 (암호 입력창이 뜰 수 있습니다)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "==> 확인"
security find-identity -v -p codesigning | grep "$CERT_NAME"
echo "완료."
