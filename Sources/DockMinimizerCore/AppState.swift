// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import Foundation

/// 판정에 필요한 프론트모스트 앱의 상태. AX 조회 결과를 미리 계산해 담아 둔 값이다.
///
/// 두 플래그가 모두 필요하다. `hasVisibleWindows == false` 하나만으로는
/// "전부 최소화됨"(복원해야 함)과 "윈도우가 아예 없음"(메뉴바 전용 앱, 개입 불가)을
/// 구분할 수 없다.
public struct AppState: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String
    /// 최소화되지 않은 대상 윈도우가 하나 이상 있는가.
    public let hasVisibleWindows: Bool
    /// 최소화된 대상 윈도우가 하나 이상 있는가.
    public let hasMinimizedWindows: Bool

    public init(
        pid: pid_t,
        bundleID: String,
        hasVisibleWindows: Bool,
        hasMinimizedWindows: Bool
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.hasVisibleWindows = hasVisibleWindows
        self.hasMinimizedWindows = hasMinimizedWindows
    }
}
