// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import CoreGraphics
import Testing
@testable import DockMinimizerCore

private let safariIcon = DockItem(
    frame: CGRect(x: 0, y: 1000, width: 50, height: 50),
    bundleID: "com.apple.Safari",
    title: "Safari"
)
private let notesIcon = DockItem(
    frame: CGRect(x: 100, y: 1000, width: 50, height: 50),
    bundleID: "com.apple.Notes",
    title: "메모"
)
private let onSafari = CGPoint(x: 25, y: 1025)
private let onNotes = CGPoint(x: 125, y: 1025)

private func safari(visible: Bool, minimized: Bool) -> AppState {
    AppState(
        pid: 42,
        bundleID: "com.apple.Safari",
        hasVisibleWindows: visible,
        hasMinimizedWindows: minimized
    )
}

private func makeInput(
    point: CGPoint = onSafari,
    modifiers: ClickModifiers = [],
    items: [DockItem] = [safariIcon, notesIcon],
    frontmost: AppState? = safari(visible: true, minimized: false),
    isEnabled: Bool = true,
    excluded: Set<String> = []
) -> RouterInput {
    RouterInput(
        point: point,
        modifiers: modifiers,
        snapshot: DockSnapshot(items: items),
        frontmost: frontmost,
        isEnabled: isEnabled,
        excludedBundleIDs: excluded
    )
}

// MARK: - 개입하지 않는 경우

@Test("비활성 상태에서는 개입하지 않는다")
func ignoresWhenDisabled() {
    #expect(ClickRouter.decide(makeInput(isEnabled: false)) == .ignore)
}

@Test("수정자 키가 눌린 클릭은 개입하지 않는다")
func ignoresModifiedClicks() {
    for modifier in [ClickModifiers.command, .option, .control, .shift] {
        #expect(ClickRouter.decide(makeInput(modifiers: modifier)) == .ignore)
    }
}

@Test("Dock 아이콘 바깥 클릭은 개입하지 않는다")
func ignoresClicksOutsideDock() {
    #expect(ClickRouter.decide(makeInput(point: CGPoint(x: 500, y: 300))) == .ignore)
}

@Test("bundleID를 알 수 없는 아이콘은 개입하지 않는다")
func ignoresItemsWithoutBundleID() {
    let trash = DockItem(frame: safariIcon.frame, bundleID: nil, title: "휴지통")
    #expect(ClickRouter.decide(makeInput(items: [trash])) == .ignore)
}

@Test("제외 목록에 있는 앱은 개입하지 않는다")
func ignoresExcludedApps() {
    #expect(ClickRouter.decide(makeInput(excluded: ["com.apple.Safari"])) == .ignore)
}

@Test("프론트모스트가 아닌 앱의 아이콘 클릭은 개입하지 않는다 — Dock이 활성화·복원한다")
func ignoresNonFrontmostApp() {
    #expect(ClickRouter.decide(makeInput(point: onNotes)) == .ignore)
}

@Test("프론트모스트 앱이 없으면 개입하지 않는다")
func ignoresWhenNoFrontmostApp() {
    #expect(ClickRouter.decide(makeInput(frontmost: nil)) == .ignore)
}

@Test("윈도우가 아예 없는 메뉴바 전용 앱은 개입하지 않는다")
func ignoresAppWithNoWindows() {
    let front = safari(visible: false, minimized: false)
    #expect(ClickRouter.decide(makeInput(frontmost: front)) == .ignore)
}

// MARK: - 3분기 판정

@Test("프론트모스트 + 보이는 윈도우 있음 → 최소화")
func minimizesFrontmostAppWithVisibleWindows() {
    #expect(ClickRouter.decide(makeInput()) == .minimize(pid: 42))
}

@Test("프론트모스트 + 보이는 윈도우 없고 최소화된 윈도우 있음 → 복원")
func restoresFrontmostAppWithOnlyMinimizedWindows() {
    let front = safari(visible: false, minimized: true)
    #expect(ClickRouter.decide(makeInput(frontmost: front)) == .restore(pid: 42))
}

@Test("일부만 최소화된 앱은 남은 것을 최소화한다")
func minimizesWhenPartiallyMinimized() {
    let front = safari(visible: true, minimized: true)
    #expect(ClickRouter.decide(makeInput(frontmost: front)) == .minimize(pid: 42))
}

@Test("최소화 → 복원 → 재최소화가 순환한다")
func minimizeRestoreMinimizeCycle() {
    // 1회차: 보이는 윈도우가 있으니 최소화
    #expect(ClickRouter.decide(makeInput()) == .minimize(pid: 42))

    // 2회차: 전부 최소화된 상태. Dock은 복원하지 않으므로 우리가 복원
    let allMinimized = makeInput(frontmost: safari(visible: false, minimized: true))
    #expect(ClickRouter.decide(allMinimized) == .restore(pid: 42))

    // 3회차: 복원되었으니 다시 최소화
    #expect(ClickRouter.decide(makeInput()) == .minimize(pid: 42))
}
