// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import CoreGraphics
import Testing
@testable import DockMinimizerCore

private func item(_ x: CGFloat, _ bundleID: String?) -> DockItem {
    DockItem(
        frame: CGRect(x: x, y: 1000, width: 50, height: 50),
        bundleID: bundleID,
        title: bundleID
    )
}

@Test("좌표가 아이콘 안이면 그 아이콘을 반환한다")
func hitTestInside() {
    let snapshot = DockSnapshot(items: [item(0, "a"), item(100, "b")])
    #expect(snapshot.item(at: CGPoint(x: 120, y: 1020))?.bundleID == "b")
}

@Test("아이콘 사이의 빈 공간은 nil을 반환한다")
func hitTestBetweenIcons() {
    let snapshot = DockSnapshot(items: [item(0, "a"), item(100, "b")])
    #expect(snapshot.item(at: CGPoint(x: 75, y: 1020)) == nil)
}

@Test("Dock 바깥 좌표는 nil을 반환한다")
func hitTestOutside() {
    let snapshot = DockSnapshot(items: [item(0, "a")])
    #expect(snapshot.item(at: CGPoint(x: 500, y: 300)) == nil)
}

@Test("아이콘의 왼쪽·위쪽 경계는 포함된다")
func hitTestLeadingEdgeIsInclusive() {
    let snapshot = DockSnapshot(items: [item(0, "a")])
    #expect(snapshot.item(at: CGPoint(x: 0, y: 1000))?.bundleID == "a")
}

@Test("아이콘의 오른쪽 경계는 포함되지 않는다")
func hitTestTrailingEdgeIsExclusive() {
    let snapshot = DockSnapshot(items: [item(0, "a")])
    #expect(snapshot.item(at: CGPoint(x: 50, y: 1020)) == nil)
}

@Test("빈 스냅샷은 항상 nil을 반환한다")
func hitTestEmptySnapshot() {
    #expect(DockSnapshot.empty.item(at: CGPoint(x: 10, y: 1010)) == nil)
}
