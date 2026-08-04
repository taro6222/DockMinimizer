// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import AppKit
import ApplicationServices

// 설치된 DockMinimizer.app의 메뉴바와 설정 창을 접근성 API로 직접 읽고 눌러 검증한다.
//
//   swift run DockProbe ui
//
// 눈으로 확인하기 어려운 것들을 잡는다. 특히 메뉴바와 설정 창의 동기화는 창을 닫았다
// 다시 열어야 드러나므로 수동으로는 놓치기 쉽다.
//
// MenuBarController.swift 나 SettingsWindow.swift 를 고쳤다면 다시 돌릴 것.

// MARK: - AX 헬퍼

/// `describe`는 값이 없을 때 "-"를 돌려주므로, 빈 문자열 판정에는 이쪽을 쓴다.
private func text(_ element: AXUIElement, _ name: String) -> String {
    guard let value = attribute(element, name) else { return "" }
    return "\(value)"
}

private func perform(_ element: AXUIElement, _ action: String) -> Bool {
    AXUIElementPerformAction(element, action as CFString) == .success
}

private func appElement() -> AXUIElement? {
    guard let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.changhun.dockminimizer").first else {
        return nil
    }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 3.0)
    return element
}

/// 메뉴바 상태 항목의 메뉴 항목들.
///
/// `LSUIElement` 앱이라 `AXMenuBar`는 nil이고 상태 항목은 `AXExtrasMenuBar` 아래에 있다.
/// 메뉴를 열지 않아도 하위 항목을 읽고 `AXPress`를 보낼 수 있다.
private func menuItems(_ app: AXUIElement) -> [AXUIElement] {
    guard let extras = attribute(app, "AXExtrasMenuBar") else { return [] }
    var result: [AXUIElement] = []
    for statusItem in children(extras as! AXUIElement) {
        for menu in children(statusItem) {
            result.append(contentsOf: children(menu))
        }
    }
    return result
}

private func menuItem(_ app: AXUIElement, titled title: String) -> AXUIElement? {
    menuItems(app).first { text($0, kAXTitleAttribute as String) == title }
}

/// 메뉴 항목의 체크 상태. `AXMenuItemMarkChar`가 비어 있으면 꺼짐이다.
private func isChecked(_ item: AXUIElement) -> Bool {
    !text(item, kAXMenuItemMarkCharAttribute as String).isEmpty
}

private func settingsWindow(_ app: AXUIElement) -> AXUIElement? {
    let windows = (attribute(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    return windows.first { text($0, kAXTitleAttribute as String).contains("설정") }
}

private func descend(
    _ element: AXUIElement, role: String, label: String, depth: Int = 0
) -> AXUIElement? {
    guard depth <= 10 else { return nil }
    for child in children(element) {
        if text(child, kAXRoleAttribute as String) == role {
            // 요소 종류마다 문구가 담기는 속성이 다르다.
            // AXCheckBox는 AXDescription에, AXStaticText는 AXValue에 들어 있다.
            let combined = [
                text(child, kAXTitleAttribute as String),
                text(child, kAXDescriptionAttribute as String),
                text(child, kAXValueAttribute as String),
            ].joined(separator: " ")
            if combined.contains(label) { return child }
        }
        if let found = descend(child, role: role, label: label, depth: depth + 1) { return found }
    }
    return nil
}

private func openSettings(_ app: AXUIElement) {
    guard settingsWindow(app) == nil, let item = menuItem(app, titled: "설정...") else { return }
    _ = perform(item, kAXPressAction as String)
    wait(1.5)
}

private func closeSettings(_ app: AXUIElement) {
    guard let window = settingsWindow(app),
          let button = attribute(window, "AXCloseButton") else { return }
    _ = perform(button as! AXUIElement, kAXPressAction as String)
    wait(0.8)
}

// MARK: - 검증

func runUIVerification() -> Int32 {
    guard let app = appElement() else {
        print("DockMinimizer가 실행 중이 아닙니다. `./Scripts/install.sh` 후 다시 실행하세요.")
        return 2
    }
    closeSettings(app)

    print("=== 1. 메뉴바 구성 ===")
    let titles = menuItems(app).map { text($0, kAXTitleAttribute as String) }
    guard !titles.isEmpty else {
        print("  메뉴 항목을 읽지 못했습니다. 접근성 권한을 확인하세요.")
        return 2
    }
    for expected in ["활성화", "로그인 시 시작", "설정...", "종료"] {
        check("'\(expected)' 항목 존재", titles.contains(expected), "")
    }
    // 맨 위 상태 레이블은 정보 표시용이라 눌리지 않아야 한다.
    // 문구는 상황에 따라 권한 / 확대 / 재실행 안내 중 하나다.
    let statusLabel = menuItems(app).first { item in
        let title = text(item, kAXTitleAttribute as String)
        return title.contains("권한") || title.contains("확대")
    }
    if let statusLabel {
        let enabled = (attribute(statusLabel, kAXEnabledAttribute as String) as? Bool) ?? true
        check("상태 레이블은 비활성", !enabled, text(statusLabel, kAXTitleAttribute as String))
    } else {
        check("상태 레이블 존재", false, "권한/확대 상태를 알리는 항목이 없다")
    }
    // 권한과 탭이 모두 정상이면 '재실행'은 숨겨져야 한다.
    check("'재실행' 항목 숨김", !titles.contains("재실행"),
          "권한·탭이 정상일 때의 기대값. 보인다면 탭이 죽어 있다는 뜻이다")

    print("\n=== 2. 설정 창 ===")
    openSettings(app)
    guard let window = settingsWindow(app) else {
        check("설정 창 열림", false, "창을 찾지 못했다")
        return verifySummary()
    }
    check("설정 창 열림", true, text(window, kAXTitleAttribute as String))
    check("활성화 체크박스 존재",
          descend(window, role: "AXCheckBox", label: "최소화 활성화") != nil, "")
    check("권한 상태 표시",
          descend(window, role: "AXStaticText", label: "권한") != nil, "")
    if let remove = descend(window, role: "AXButton", label: "제거") {
        let enabled = (attribute(remove, kAXEnabledAttribute as String) as? Bool) ?? true
        check("선택 없을 때 '제거' 비활성", !enabled, "enabled=\(enabled)")
    } else {
        check("'제거' 버튼 존재", false, "")
    }

    print("\n=== 3. 메뉴바 ↔ 설정 창 동기화 ===")
    // 설정 창이 열려 있는 동안 메뉴바에서 값을 바꾸면, 창을 다시 열었을 때 반영되어야 한다.
    // 대칭이 깨지면 두 화면이 서로 다른 값을 보여 준다.
    func checkboxOn() -> Bool? {
        guard let window = settingsWindow(app),
              let box = descend(window, role: "AXCheckBox", label: "최소화 활성화") else { return nil }
        return text(box, kAXValueAttribute as String) == "1"
    }
    func menuOn() -> Bool? {
        menuItem(app, titled: "활성화").map(isChecked)
    }
    let initialMenu = menuOn()
    check("초기 상태 일치", checkboxOn() == initialMenu,
          "체크박스=\(checkboxOn().map(String.init) ?? "?") 메뉴=\(initialMenu.map(String.init) ?? "?")")

    if let item = menuItem(app, titled: "활성화") { _ = perform(item, kAXPressAction as String) }
    wait(1.2)
    let toggledMenu = menuOn()
    closeSettings(app)
    openSettings(app)
    check("창을 다시 열면 메뉴바 변경이 반영됨", checkboxOn() == toggledMenu,
          "체크박스=\(checkboxOn().map(String.init) ?? "?") 메뉴=\(toggledMenu.map(String.init) ?? "?")")

    // 원상복구
    if menuOn() != initialMenu, let item = menuItem(app, titled: "활성화") {
        _ = perform(item, kAXPressAction as String)
        wait(1.2)
    }
    closeSettings(app)
    openSettings(app)
    check("원상복구", menuOn() == initialMenu && checkboxOn() == initialMenu,
          "메뉴=\(menuOn().map(String.init) ?? "?") 체크박스=\(checkboxOn().map(String.init) ?? "?")")
    closeSettings(app)

    print("\n=== 4. 로그인 시 시작 토글 ===")
    // SMAppService 상태는 메뉴 체크마크로 읽는다.
    // `sfltool dumpbtm`은 토글 직후 응답이 멈추는 일이 있어 판정 수단으로 쓰지 않는다.
    if let item = menuItem(app, titled: "로그인 시 시작") {
        let before = isChecked(item)
        print("  검사 전 상태: \(before ? "켜짐" : "꺼짐")")
        _ = perform(item, kAXPressAction as String)
        wait(2.0)
        let toggled = menuItem(app, titled: "로그인 시 시작").map(isChecked)
        check("토글됨", toggled == !before, "\(before ? "켜짐" : "꺼짐") → \(toggled.map { $0 ? "켜짐" : "꺼짐" } ?? "?")")

        if let again = menuItem(app, titled: "로그인 시 시작") {
            _ = perform(again, kAXPressAction as String)
            wait(2.0)
        }
        let restored = menuItem(app, titled: "로그인 시 시작").map(isChecked)
        check("검사 전 상태로 복원", restored == before,
              "현재 \(restored.map { $0 ? "켜짐" : "꺼짐" } ?? "?")")
        if restored != before {
            print("  ⚠️  복원 실패. 메뉴바에서 '로그인 시 시작'을 직접 \(before ? "켜" : "꺼")주세요.")
        }
    } else {
        check("'로그인 시 시작' 항목 존재", false, "")
    }

    return verifySummary()
}
