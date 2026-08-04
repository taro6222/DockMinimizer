// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import AppKit
@preconcurrency import ApplicationServices
import Combine

/// 접근성 권한의 현재 상태를 관찰 가능한 형태로 노출한다.
/// 이벤트 탭 생성과 AX 조회 모두 이 권한 하나로 커버된다.
@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private var timer: Timer?

    /// 권한 상태 변화를 알리는 알림은 없으므로 짧은 주기로 확인한다.
    /// 사용자가 시스템 설정에서 권한을 끄는 경우도 여기서 잡힌다.
    func startMonitoring() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let current = AXIsProcessTrusted()
                if current != self.isTrusted {
                    self.isTrusted = current
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// 시스템 권한 요청 창을 띄운다.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// 시스템 설정의 손쉬운 사용 패널을 연다.
    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
