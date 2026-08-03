import AppKit
import ApplicationServices

// Dock의 접근성 트리를 덤프하는 스파이크 도구.
// 사용법: DockProbe dump

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func describe(_ element: AXUIElement, _ name: String) -> String {
    guard let value = attribute(element, name) else { return "-" }
    return "\(value)"
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func frame(_ element: AXUIElement) -> CGRect {
    var point = CGPoint.zero
    var size = CGSize.zero
    if let raw = attribute(element, kAXPositionAttribute as String) {
        AXValueGetValue(raw as! AXValue, .cgPoint, &point)
    }
    if let raw = attribute(element, kAXSizeAttribute as String) {
        AXValueGetValue(raw as! AXValue, .cgSize, &size)
    }
    return CGRect(origin: point, size: size)
}

func attributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

/// AXList 역할을 가진 모든 엘리먼트를 깊이 우선으로 수집한다.
/// Dock은 앱 / 최근 항목 / 휴지통을 별개의 리스트로 나눠 가질 수 있으므로 전부 찾아야 한다.
func collectLists(_ element: AXUIElement, depth: Int = 0, into result: inout [AXUIElement]) {
    if depth > 6 { return }
    if describe(element, kAXRoleAttribute as String) == "AXList" {
        result.append(element)
    }
    for child in children(element) {
        collectLists(child, depth: depth + 1, into: &result)
    }
}

func dumpTree(_ element: AXUIElement, depth: Int, maxDepth: Int) {
    let pad = String(repeating: "  ", count: depth)
    let kids = children(element)
    let role = describe(element, kAXRoleAttribute as String)
    let subrole = describe(element, kAXSubroleAttribute as String)
    let title = describe(element, kAXTitleAttribute as String)
    print("\(pad)role=\(role) subrole=\(subrole) title=\(title) frame=\(frame(element)) children=\(kids.count)")
    guard depth < maxDepth else { return }
    for child in kids {
        dumpTree(child, depth: depth + 1, maxDepth: maxDepth)
    }
}

// MARK: - 실행

print("=== 권한 ===")
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
guard AXIsProcessTrusted() else {
    print("접근성 권한이 없습니다. 이 프로세스를 실행한 앱(터미널 등)에")
    print("시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용 에서 권한을 부여한 뒤 다시 실행하세요.")
    exit(1)
}

guard let dock = NSRunningApplication
    .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    print("Dock 프로세스를 찾을 수 없습니다.")
    exit(1)
}
print("Dock pid: \(dock.processIdentifier)")

let dockApp = AXUIElementCreateApplication(dock.processIdentifier)
AXUIElementSetMessagingTimeout(dockApp, 1.0)

let mode = CommandLine.arguments.dropFirst().first ?? "dump"

if mode == "dump" {
    print("\n=== 트리 (깊이 3) ===")
    dumpTree(dockApp, depth: 0, maxDepth: 3)

    print("\n=== 발견된 AXList ===")
    var lists: [AXUIElement] = []
    collectLists(dockApp, into: &lists)
    print("AXList 개수: \(lists.count)")

    for (index, list) in lists.enumerated() {
        let items = children(list)
        print("\n--- LIST[\(index)] frame=\(frame(list)) items=\(items.count)")
        for item in items {
            let title = describe(item, kAXTitleAttribute as String)
            let subrole = describe(item, kAXSubroleAttribute as String)
            let url = describe(item, "AXURL")
            let running = describe(item, "AXIsApplicationRunning")
            print("  title=\(title)")
            print("    subrole=\(subrole) frame=\(frame(item))")
            print("    AXURL=\(url) AXIsApplicationRunning=\(running)")
            print("    attributes=\(attributeNames(item).joined(separator: ", "))")
        }
    }

    print("\n=== 화면 ===")
    for screen in NSScreen.screens {
        print("frame=\(screen.frame) visibleFrame=\(screen.visibleFrame)")
    }
}

if mode == "experiment" {
    let appName = CommandLine.arguments.dropFirst(2).first ?? "메모"
    let bundleID = CommandLine.arguments.dropFirst(3).first ?? "com.apple.Notes"
    experimentCoordinateSpace()
    experimentMagnification()
    experimentDockDefaultBehavior(appName: appName, bundleID: bundleID)
    print("\n########## 실측 완료 ##########")
}
