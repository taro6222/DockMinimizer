// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import AppKit
import ApplicationServices

// 설치된 DockMinimizer.app의 실동작 검증.
//
// 사람이 Dock을 클릭하고 눈으로 보는 대신 합성 클릭을 보내고 AX로 윈도우 상태를 읽는다.
// 이 방식 덕분에 Phase 0에서 잘못 내린 결론(리슨 전용 탭으로 충분하다)을 구현 단계에서
// 잡을 수 있었다. Dock이나 이벤트 탭 관련 코드를 고친 뒤에는 반드시 다시 돌릴 것.
//
//   swift run DockProbe verify   # 설치된 앱의 동작 검증
//   swift run DockProbe race     # 리슨 전용 탭 회귀 테스트 (앱을 끄고 실행)

// MARK: - 공용

func iconRect(bundleID: String) -> CGRect? {
    appDockItems().first { item in
        guard let url = item.url else { return false }
        return Bundle(url: url)?.bundleIdentifier == bundleID
    }?.frame
}

/// 클릭을 보낸다. **반드시 HID 레벨로 보내야 한다.**
/// `.cgSessionEventTap`으로 post한 합성 클릭은 Dock에 전달되지 않아, 모든 관찰이
/// "아무 일도 일어나지 않음"으로 나오고 잘못된 결론에 이른다 (실측으로 확인).
func postClick(at point: CGPoint, flags: CGEventFlags = []) {
    let down = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: point, mouseButton: .left
    )
    let up = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: point, mouseButton: .left
    )
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    wait(0.04)
    up?.post(tap: .cghidEventTap)
}

func windowCounts(pid: pid_t) -> (visible: Int, minimized: Int) {
    let all = standardWindows(pid: pid)
    let minimized = all.filter { $0.1.minimized }.count
    return (all.count - minimized, minimized)
}

func restoreAll(pid: pid_t) {
    for (window, _) in standardWindows(pid: pid) { setMinimized(window, false) }
}

// 단일 스레드 검증 도구다. Swift 6는 전역 var를 거부하므로 박스에 담는다.
private final class Tally: @unchecked Sendable {
    var pass = 0
    var fail = 0
}
private let tally = Tally()

func check(_ name: String, _ ok: Bool, _ detail: String) {
    if ok { tally.pass += 1 } else { tally.fail += 1 }
    print("  \(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
}

func verifySummary() -> Int32 {
    print("\n=== 결과: \(tally.pass) PASS / \(tally.fail) FAIL ===")
    return tally.fail == 0 ? 0 : 1
}

// MARK: - 설치된 앱의 동작 검증

func runVerification(appName: String, bundleID: String) -> Int32 {
    guard let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID).first else {
        print("\(appName)이 실행 중이 아닙니다. 먼저 실행하세요.")
        return 2
    }
    let pid = app.processIdentifier
    let cursorHome = CGEvent(source: nil)?.location ?? .zero

    func prepare() {
        restoreAll(pid: pid)
        wait(0.8)
        app.activate()
        wait(1.2)
    }
    func clickOwnIcon(flags: CGEventFlags = []) {
        guard let rect = iconRect(bundleID: bundleID) else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        warp(to: center)
        wait(0.35)
        postClick(at: center, flags: flags)
    }

    print("=== 1. 최소화 ↔ 복원 토글 ===")
    prepare()
    var states: [String] = []
    for _ in 1...4 {
        clickOwnIcon()
        wait(1.6)
        let c = windowCounts(pid: pid)
        states.append("보임=\(c.visible)/최소화=\(c.minimized)")
    }
    let alternates = windowCounts(pid: pid).minimized == 0
    check("4회 클릭이 번갈아 동작", alternates, states.joined(separator: " → "))

    print("\n=== 2. 빠른 연속 클릭 (정착 구간) ===")
    // 느린 클릭만 검증하면 정착 구간을 전혀 건드리지 못한다. 캐시가 타이머로 이미
    // 갱신된 뒤에 다음 클릭이 오기 때문이다.
    for gap in [0.05, 0.15, 0.3] {
        prepare()
        guard let rect = iconRect(bundleID: bundleID) else { break }
        var center = CGPoint(x: rect.midX, y: rect.midY)
        warp(to: center)
        wait(0.35)
        postClick(at: center)
        wait(gap)
        // 최소화로 Dock이 재정렬되므로 두 번째 클릭 전에 위치를 다시 읽는다.
        if let fresh = iconRect(bundleID: bundleID) {
            center = CGPoint(x: fresh.midX, y: fresh.midY)
            warp(to: center)
        }
        postClick(at: center)
        wait(2.0)
        let c = windowCounts(pid: pid)
        check("\(Int(gap * 1000))ms 간격 2회 → 복원됨", c.visible > 0 && c.minimized == 0,
              "보임=\(c.visible) 최소화=\(c.minimized)")
    }

    print("\n=== 3. 수정자 키 클릭은 개입하지 않는다 ===")
    for (label, flags) in [("⌘", CGEventFlags.maskCommand), ("옵션", .maskAlternate)] {
        prepare()
        clickOwnIcon(flags: flags)
        wait(1.6)
        let c = windowCounts(pid: pid)
        check("\(label)클릭 미개입", c.minimized == 0, "보임=\(c.visible) 최소화=\(c.minimized)")
    }

    print("\n=== 4. 프론트모스트가 아닌 앱 클릭은 평소대로 활성화 ===")
    prepare()
    let other = "com.apple.Safari"
    if let rect = iconRect(bundleID: other) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        warp(to: center)
        wait(0.35)
        postClick(at: center)
        wait(2.0)
        let activated = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == other
        check("Safari 활성화", activated,
              "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        check("대상 앱은 최소화되지 않음", windowCounts(pid: pid).minimized == 0, "")
    } else {
        print("  SKIP — Safari 아이콘 없음")
    }

    print("\n=== 5. 최소화로 Dock이 재정렬된 직후 이웃 아이콘 클릭 ===")
    // 최소화된 윈도우가 Dock 아이콘으로 추가되면 가운데 정렬이 다시 계산되어
    // 모든 아이콘의 x좌표가 밀린다. 갱신하지 않으면 다음 클릭이 이웃 앱을 건드린다.
    prepare()
    let beforeX = iconRect(bundleID: other)?.minX
    clickOwnIcon()
    wait(1.5)
    let afterX = iconRect(bundleID: other)?.minX
    if let b = beforeX, let a = afterX {
        print("  (참고) Safari 아이콘 x 이동량 = \(abs(a - b))pt")
    }
    check("대상 앱 최소화됨", windowCounts(pid: pid).minimized >= 1, "")
    if let rect = iconRect(bundleID: other) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        warp(to: center)
        wait(0.35)
        postClick(at: center)
        wait(2.0)
        check("이웃(Safari) 활성화",
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == other,
              "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        check("대상 앱은 여전히 최소화", windowCounts(pid: pid).minimized >= 1, "")
    }

    restoreAll(pid: pid)
    warp(to: cursorHome)
    return verifySummary()
}

// MARK: - 리슨 전용 탭 회귀 테스트

/// 이 프로젝트에서 가장 미묘한 버그의 회귀 테스트다.
///
/// 리슨 전용 탭에서는 클릭이 Dock에도 전달되고, Dock이 우리 최소화를 100ms 안에
/// 원상복구한다. `AXUIElementSetAttributeValue`는 `.success`를 반환하고 앱 로그도
/// 정상이라 증상은 "아무 일도 일어나지 않음"으로만 보인다.
///
/// **DockMinimizer를 종료하고 실행할 것** (`pkill -x DockMinimizer`).
/// 앱이 살아 있으면 앱의 삼킴이 이 측정을 무효화한다.
func runRaceCheck(bundleID: String) -> Int32 {
    guard let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID).first else {
        print("대상 앱이 실행 중이 아닙니다."); return 2
    }
    if NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.changhun.dockminimizer").first != nil {
        print("경고: DockMinimizer가 실행 중입니다. `pkill -x DockMinimizer` 후 다시 실행하세요.")
        return 2
    }
    let pid = app.processIdentifier
    let cursorHome = CGEvent(source: nil)?.location ?? .zero
    func firstWindow() -> AXUIElement? { standardWindows(pid: pid).first?.0 }
    func isMinimized() -> Bool { standardWindows(pid: pid).first?.1.minimized ?? false }

    func prepare() {
        restoreAll(pid: pid); wait(0.8); app.activate(); wait(1.2)
    }

    print("=== 대조군: 클릭 없이 최소화만 ===")
    prepare()
    if let w = firstWindow() { setMinimized(w, true) }
    wait(1.2)
    let controlHolds = isMinimized()
    check("최소화가 유지된다", controlHolds, "minimized=\(isMinimized())")

    print("\n=== 실험군: Dock 클릭과 같은 시점에 최소화 ===")
    prepare()
    guard let rect = iconRect(bundleID: bundleID) else { print("아이콘 없음"); return 2 }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    warp(to: center)
    wait(0.35)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
    if let w = firstWindow() { setMinimized(w, true) }
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
    wait(1.5)
    let reverted = !isMinimized()
    check("Dock이 되돌린다 (예상된 동작)", reverted, "minimized=\(isMinimized())")

    print("""

    두 결과가 모두 PASS면 "클릭을 삼켜야 한다"는 전제가 여전히 유효하다.
    실험군이 FAIL(= 최소화가 유지됨)이면 macOS 동작이 바뀐 것이므로
    리슨 전용 탭으로 되돌릴 수 있는지 재검토할 것.
    """)

    restoreAll(pid: pid)
    warp(to: cursorHome)
    return verifySummary()
}
