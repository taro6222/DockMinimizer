// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import AppKit
import ApplicationServices

// Phase 0의 나머지 실측을 자동화한다.
// 사람이 Dock을 클릭하고 눈으로 관찰하는 대신, 합성 클릭을 보내고 AX로 윈도우의
// 최소화 상태 변화를 직접 읽는다. 관찰이 재현 가능해지고 판정이 애매해지지 않는다.

// MARK: - 공용

func dockElement() -> AXUIElement? {
    guard let dock = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    let element = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 1.0)
    return element
}

/// Dock의 앱 아이콘만 (구분자, 폴더, 최소화된 윈도우, 휴지통 제외)
func appDockItems() -> [(title: String, frame: CGRect, url: URL?)] {
    guard let dock = dockElement() else { return [] }
    var lists: [AXUIElement] = []
    collectLists(dock, into: &lists)
    var result: [(String, CGRect, URL?)] = []
    for list in lists {
        for item in children(list) {
            guard describe(item, kAXSubroleAttribute as String) == "AXApplicationDockItem" else {
                continue
            }
            let title = describe(item, kAXTitleAttribute as String)
            result.append((title, frame(item), attribute(item, "AXURL") as? URL))
        }
    }
    return result
}

func dockItem(titled title: String) -> (title: String, frame: CGRect, url: URL?)? {
    appDockItems().first { $0.title == title }
}

func warp(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(1)
}

func wait(_ seconds: Double) {
    usleep(useconds_t(seconds * 1_000_000))
}

func synthesizeClick(at point: CGPoint) {
    warp(to: point)
    wait(0.15)
    let down = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: point, mouseButton: .left
    )
    let up = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: point, mouseButton: .left
    )
    // 반드시 HID 레벨로 보낸다. .cgSessionEventTap으로 post한 클릭은 Dock에 전달되지 않아
    // "아무 일도 일어나지 않는다"는 잘못된 관찰을 만든다 (실측으로 확인).
    down?.post(tap: .cghidEventTap)
    wait(0.08)
    up?.post(tap: .cghidEventTap)
}

// MARK: - 대상 앱의 윈도우 상태

struct WindowState {
    let index: Int
    let title: String
    let subrole: String
    let minimized: Bool
    let fullScreen: Bool
}

/// 최소화 대상이 되는 윈도우.
///
/// subrole == AXStandardWindow 로 거르면 안 된다. 실측 결과 최소화된 윈도우는 subrole이
/// AXDialog로 바뀌어 필터에서 빠지고, 그러면 "윈도우가 사라졌다"는 잘못된 관찰이 나온다.
/// 대신 AXMinimized 속성을 가진 윈도우를 받고, 최소화 대상이 아닌 subrole만 제외한다.
let excludedSubroles: Set<String> = ["AXSheet", "AXSystemDialog", "AXSystemFloatingWindow"]

func standardWindows(pid: pid_t) -> [(AXUIElement, WindowState)] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    let all = (attribute(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    var result: [(AXUIElement, WindowState)] = []
    for (index, window) in all.enumerated() {
        let subrole = describe(window, kAXSubroleAttribute as String)
        guard !excludedSubroles.contains(subrole) else { continue }
        guard let minimized = attribute(window, kAXMinimizedAttribute as String) as? Bool
        else { continue }
        result.append((window, WindowState(
            index: index,
            title: describe(window, kAXTitleAttribute as String),
            subrole: subrole,
            minimized: minimized,
            fullScreen: (attribute(window, "AXFullScreen") as? Bool) ?? false
        )))
    }
    return result
}

func setMinimized(_ window: AXUIElement, _ value: Bool) {
    AXUIElementSetAttributeValue(
        window, kAXMinimizedAttribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse
    )
}

func describeWindows(_ pid: pid_t) -> String {
    standardWindows(pid: pid).map { _, state in
        "[\(state.index)] \"\(state.title)\" subrole=\(state.subrole) minimized=\(state.minimized) fullScreen=\(state.fullScreen)"
    }.joined(separator: "\n    ")
}

// MARK: - 실험 1: 좌표계

func experimentCoordinateSpace() {
    print("\n########## 실험 1: AX 좌표와 CGEvent 좌표가 같은 공간인가 ##########")
    guard let item = appDockItems().first else {
        print("결과: 실패 — Dock 앱 아이콘을 찾지 못함")
        return
    }
    let target = CGPoint(x: item.frame.midX, y: item.frame.midY)
    let before = CGEvent(source: nil)?.location ?? .zero
    warp(to: target)
    wait(0.2)
    let after = CGEvent(source: nil)?.location ?? .zero

    print("대상 아이콘   : \(item.title) frame=\(item.frame)")
    print("워프 목표     : \(target)")
    print("워프 후 커서  : \(after)")
    let dx = abs(after.x - target.x), dy = abs(after.y - target.y)
    print("오차          : dx=\(dx) dy=\(dy)")
    print("결과: \(dx < 1 && dy < 1 ? "일치 — 좌표 변환 불필요" : "불일치 — 변환식 필요")")
    warp(to: before)
}

// MARK: - 실험 2: Dock 확대

func experimentMagnification() {
    print("\n########## 실험 2: AX 프레임이 Dock 확대를 실시간 반영하는가 ##########")
    let magnification = UserDefaults(suiteName: "com.apple.dock")?
        .bool(forKey: "magnification") ?? false
    print("현재 magnification 설정: \(magnification)")
    guard magnification else {
        print("결과: 판정 불가 — 확대가 꺼져 있음. 켜고 다시 실행할 것")
        return
    }
    guard let items = Optional(appDockItems()), items.count > 4 else {
        print("결과: 실패 — 아이콘이 너무 적음")
        return
    }
    let probe = items[items.count / 2]
    let away = CGPoint(x: probe.frame.midX, y: max(probe.frame.minY - 400, 50))
    let before = CGEvent(source: nil)?.location ?? .zero

    warp(to: away)
    wait(0.4)
    let farFrame = dockItem(titled: probe.title)?.frame ?? .null

    warp(to: CGPoint(x: probe.frame.midX, y: probe.frame.midY))
    wait(0.4)
    let hoverFrame = dockItem(titled: probe.title)?.frame ?? .null

    print("대상 아이콘        : \(probe.title)")
    print("커서 멀리 있을 때  : \(farFrame)")
    print("커서 올렸을 때     : \(hoverFrame)")
    if farFrame.equalTo(hoverFrame) {
        print("결과: Case B — AX 프레임이 정적. 확대 중에는 히트테스트가 어긋나므로 기능 일시 중지")
    } else {
        print("결과: Case A — AX 프레임이 확대를 실시간 반영. 커서 연동 고속 갱신 필요")
    }
    warp(to: before)
}

// MARK: - 실험 3: Plan A / Plan B

/// 프론트모스트 앱의 Dock 아이콘을 클릭했을 때 Dock의 기본 동작이 무엇인지 측정한다.
/// 리슨 전용 탭(Plan A)에서는 클릭이 Dock에 그대로 전달되므로, Dock이 최소화된 윈도우를
/// 복원한다면 우리의 비동기 최소화와 경쟁하게 된다. 그 경우 Plan B가 강제된다.
func experimentDockDefaultBehavior(appName: String, bundleID: String) {
    print("\n########## 실험 3: 프론트모스트 앱 아이콘 클릭 시 Dock의 기본 동작 ##########")
    print("대상: \(appName) (\(bundleID))")

    guard let item = dockItem(titled: appName) else {
        print("결과: 실패 — Dock에서 '\(appName)' 아이콘을 찾지 못함")
        return
    }
    guard let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID).first else {
        print("결과: 실패 — \(appName)이 실행 중이 아님")
        return
    }
    let pid = app.processIdentifier
    let iconCenter = CGPoint(x: item.frame.midX, y: item.frame.midY)
    let cursorHome = CGEvent(source: nil)?.location ?? .zero

    func activateAndSettle() {
        app.activate()
        wait(0.6)
    }

    // --- 상태 1: 모든 윈도우가 보임 ---
    activateAndSettle()
    for (window, state) in standardWindows(pid: pid) where state.minimized {
        setMinimized(window, false)
    }
    wait(0.6)
    activateAndSettle()
    print("\n[상태 1] 모든 윈도우가 보이는 프론트모스트 앱")
    print("  클릭 전:\n    \(describeWindows(pid))")
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        print("  결과: 실패 — \(appName)이 프론트모스트가 되지 않음")
        warp(to: cursorHome)
        return
    }
    synthesizeClick(at: iconCenter)
    wait(1.2)
    print("  클릭 후:\n    \(describeWindows(pid))")
    let state1Minimized = standardWindows(pid: pid).filter { $0.1.minimized }.count
    print("  → 최소화된 윈도우 수: \(state1Minimized) (0이면 Dock이 아무 것도 안 함)")

    // --- 상태 2: 모든 윈도우가 최소화됨 ---
    activateAndSettle()
    for (window, _) in standardWindows(pid: pid) {
        setMinimized(window, true)
    }
    wait(1.0)
    let front2 = NSWorkspace.shared.frontmostApplication
    print("\n[상태 2] 모든 윈도우가 최소화된 프론트모스트 앱  ← Plan A/B의 핵심 판정")
    print("  프론트모스트: \(front2?.localizedName ?? "-") (대상과 일치=\(front2?.processIdentifier == pid))")
    print("  클릭 전:\n    \(describeWindows(pid))")
    synthesizeClick(at: iconCenter)
    wait(1.5)
    print("  클릭 후:\n    \(describeWindows(pid))")
    let restored = standardWindows(pid: pid).filter { !$0.1.minimized }.count
    print("  → 복원된 윈도우 수: \(restored)")
    if restored > 0 {
        print("  ★ Dock이 복원한다 → Plan B 강제 (액티브 탭으로 클릭을 삼켜야 함)")
    } else {
        print("  ★ Dock이 아무 것도 안 한다 → 이 상태에서는 Plan A 가능")
    }

    // --- 상태 3: 일부만 최소화됨 ---
    activateAndSettle()
    let windows = standardWindows(pid: pid)
    if windows.count >= 2 {
        for (window, _) in windows { setMinimized(window, false) }
        wait(0.6)
        activateAndSettle()
        if let first = standardWindows(pid: pid).first { setMinimized(first.0, true) }
        wait(0.8)
        print("\n[상태 3] 일부만 최소화된 프론트모스트 앱")
        print("  클릭 전:\n    \(describeWindows(pid))")
        synthesizeClick(at: iconCenter)
        wait(1.5)
        print("  클릭 후:\n    \(describeWindows(pid))")
        let stillMinimized = standardWindows(pid: pid).filter { $0.1.minimized }.count
        print("  → 아직 최소화된 윈도우 수: \(stillMinimized)")
        print(stillMinimized == 0
            ? "  ★ Dock이 최소화된 것을 복원한다 → Plan B 강제"
            : "  ★ Dock이 복원하지 않는다")
    } else {
        print("\n[상태 3] 건너뜀 — 표준 윈도우가 \(windows.count)개뿐이라 혼합 상태를 만들 수 없음")
    }

    // 정리
    for (window, _) in standardWindows(pid: pid) { setMinimized(window, false) }
    warp(to: cursorHome)
}
