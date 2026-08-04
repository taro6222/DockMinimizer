// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import AppKit
import ApplicationServices

/// AX API의 C 스타일 인터페이스를 감싸는 얇은 래퍼.
/// 여기 있는 함수는 전부 크로스 프로세스 IPC이므로 **이벤트 탭 콜백에서 호출 금지**.
enum AX {
    /// AX 호출이 무한정 블록되지 않도록 하는 기본 타임아웃(초).
    static let messagingTimeout: Float = 0.5

    static func application(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else {
            return nil
        }
        return result
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        value(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        value(element, name) as? Bool
    }

    static func url(_ element: AXUIElement, _ name: String) -> URL? {
        value(element, name) as? URL
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    static func windows(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let rawPosition = value(element, kAXPositionAttribute as String),
              let rawSize = value(element, kAXSizeAttribute as String) else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    static func setBool(_ element: AXUIElement, _ name: String, _ newValue: Bool) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            name as CFString,
            newValue ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
    }
}
