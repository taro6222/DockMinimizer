# DockMinimizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 프론트모스트 앱의 Dock 아이콘을 클릭하면 그 앱의 윈도우를 최소화하는 macOS 메뉴바 에이전트를 만든다.

**Architecture:** `CGEventTap`으로 마우스 클릭을 관찰하고, Dock 프로세스의 접근성(AX) 트리에서 미리 캐싱해 둔 아이콘 프레임과 대조해 어느 아이콘이 눌렸는지 역산한다. 이벤트 탭 콜백은 캐시 읽기와 기하 비교만 수행하고 AX 호출을 일절 하지 않는다 — 콜백이 느리면 macOS가 탭을 조용히 죽이기 때문이다. 판정 로직은 `DockMinimizerCore`의 순수 함수 `ClickRouter.decide`로 분리해 전부 단위 테스트한다.

**Tech Stack:** Swift 6.3, SwiftPM, AppKit, SwiftUI(설정 창), ApplicationServices(AX), CoreGraphics(이벤트 탭), ServiceManagement(로그인 시작), Swift Testing

**설계 문서:** `docs/superpowers/specs/2026-07-30-dock-click-minimize-design.md`

---

## 파일 구조

| 경로 | 책임 |
|---|---|
| `Package.swift` | SPM 매니페스트. 타깃 4개 |
| `Sources/DockMinimizerCore/DockSnapshot.swift` | `DockItem`, `DockSnapshot` 값 타입과 히트테스트 |
| `Sources/DockMinimizerCore/AppState.swift` | `AppState` 값 타입 |
| `Sources/DockMinimizerCore/ClickRouter.swift` | `RouterInput`, `Decision`, 순수 판정 함수 |
| `Sources/DockMinimizerCore/Settings.swift` | 설정 모델과 UserDefaults 영속화 |
| `Sources/DockMinimizer/main.swift` | 앱 진입점 |
| `Sources/DockMinimizer/AppDelegate.swift` | 수명 관리, 모듈 배선 |
| `Sources/DockMinimizer/AXHelpers.swift` | AX 속성 조회 헬퍼 (얇은 래퍼) |
| `Sources/DockMinimizer/DockIndex.swift` | Dock AX 트리 → `DockSnapshot` 캐시와 갱신 |
| `Sources/DockMinimizer/AppStateCache.swift` | frontmost, 보이는/최소화된 윈도우 유무, 정착 구간 |
| `Sources/DockMinimizer/WindowController.swift` | 대상 앱 윈도우의 최소화·복원 |
| `Sources/DockMinimizer/EventTapController.swift` | 이벤트 탭 수명 관리와 복구 |
| `Sources/DockMinimizer/Coordinator.swift` | 위 모듈들을 잇는 조립부 |
| `Sources/DockMinimizer/PermissionsManager.swift` | 접근성 권한 확인·요청·감시 |
| `Sources/DockMinimizer/MenuBarController.swift` | NSStatusItem과 메뉴 |
| `Sources/DockMinimizer/SettingsWindow.swift` | 설정 창 (SwiftUI + NSHostingView) |
| `Sources/DockProbe/main.swift` | Phase 0 스파이크 도구 |
| `Tests/DockMinimizerCoreTests/*.swift` | 순수 로직 테스트 |
| `Resources/Info.plist` | 번들 메타데이터 |
| `Scripts/make-cert.sh` `bundle.sh` `install.sh` | 서명·빌드·설치 파이프라인 |

---

# Phase 0 — 스파이크 (게이트)

**이 Phase의 결과가 Task 13과 Task 10의 구현을 결정한다. 여기서 나온 실측값 없이는 그 두 작업을 시작하지 않는다.**

## Task 1: Dock AX 트리 실측

**Files:**
- Create: `Package.swift`
- Create: `Sources/DockProbe/main.swift`
- Create: `.gitignore`

- [ ] **Step 1: `.gitignore` 작성**

```gitignore
.build/
build/
.DS_Store
*.xcodeproj
.swiftpm/
```

- [ ] **Step 2: `Package.swift` 작성**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockMinimizer",
    platforms: [.macOS(.v14)],
    products: [
        // bundle.sh 가 `swift build --product DockMinimizer` 로 참조하므로 명시한다.
        .executable(name: "DockMinimizer", targets: ["DockMinimizer"]),
        .executable(name: "DockProbe", targets: ["DockProbe"]),
    ],
    targets: [
        .target(name: "DockMinimizerCore"),
        .executableTarget(name: "DockMinimizer", dependencies: ["DockMinimizerCore"]),
        .executableTarget(name: "DockProbe"),
        .testTarget(name: "DockMinimizerCoreTests", dependencies: ["DockMinimizerCore"]),
    ]
)
```

- [ ] **Step 3: 빌드가 통과하도록 최소 스텁 생성**

`Sources/DockMinimizerCore/Placeholder.swift`:

```swift
// Task 6에서 실제 타입으로 대체된다.
enum Placeholder {}
```

`Sources/DockMinimizer/main.swift`:

```swift
// Task 5에서 실제 앱 진입점으로 대체된다.
print("DockMinimizer stub")
```

`Tests/DockMinimizerCoreTests/PlaceholderTests.swift`:

```swift
import Testing

@Test("스캐폴딩이 빌드된다")
func scaffoldingBuilds() {
    #expect(Bool(true))
}
```

- [ ] **Step 4: `Sources/DockProbe/main.swift` 작성**

```swift
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
```

- [ ] **Step 5: 빌드**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: 접근성 권한 부여**

`DockProbe`는 터미널에서 실행되므로, 권한은 **터미널 앱**(또는 Claude Code를 실행 중인 앱)에 부여해야 한다.

시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용 에서 해당 앱을 추가하고 켠다. 이미 켜져 있다면 껐다 켠다.

- [ ] **Step 7: 프로브 실행**

Run: `swift run DockProbe 2>&1 | tee /tmp/dockprobe-dump.txt`
Expected: `AXIsProcessTrusted: true`, 그리고 Dock 아이콘들의 title/frame/AXURL이 출력된다.

`AXIsProcessTrusted: false`가 나오면 계층이 없어서가 아니라 권한이 없어서다. Step 6으로 돌아간다.

- [ ] **Step 8: 실측 결과를 기록**

다음 항목의 답을 `docs/superpowers/specs/2026-07-30-phase0-findings.md`에 표로 기록한다.

1. `AXList`가 몇 개인가? 각각 무엇을 담고 있는가 (앱 / 최근 항목 / 휴지통)?
2. dock item에 `AXURL`이 있는가? 값이 `.app` 번들 경로인가?
3. `AXIsApplicationRunning` 같은 실행 상태 속성이 있는가? 없다면 `NSWorkspace.runningApplications`와 번들 경로로 교차 조회해야 한다.
4. dock item의 `frame` y좌표가 화면 하단(예: 1000 근처)인가 상단(0 근처)인가? → 좌표 원점 확인

- [ ] **Step 9: 커밋**

```bash
git add -A
git commit -m "feat: Phase 0 Dock AX 프로브 도구 및 실측 결과"
```

## Task 2: 좌표계·클릭 동작·확대 실측

**Files:**
- Modify: `Sources/DockProbe/main.swift`
- Modify: `docs/superpowers/specs/2026-07-30-phase0-findings.md`

- [ ] **Step 1: 프로브에 `watch` 모드 추가**

`Sources/DockProbe/main.swift`의 `// MARK: - 실행` 바로 앞에 다음을 삽입한다.

```swift
// MARK: - watch 모드

/// 리슨 전용 이벤트 탭으로 클릭을 관찰하고, 그 좌표가 어느 Dock 아이콘 프레임에
/// 들어가는지 출력한다. 좌표계가 일치하는지, 그리고 Dock 기본 동작이 무엇인지 확인한다.
final class ClickWatcher {
    private var tap: CFMachPort?
    private let dockApp: AXUIElement

    init(dockApp: AXUIElement) {
        self.dockApp = dockApp
    }

    func start() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<ClickWatcher>.fromOpaque(refcon).takeUnretainedValue()
            watcher.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("이벤트 탭 생성 실패. 접근성 권한을 확인하세요.")
            exit(1)
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("클릭을 관찰합니다. Dock 아이콘을 클릭해 보세요. 중지하려면 Ctrl-C.")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard type == .leftMouseDown else { return }
        let point = event.location
        var lists: [AXUIElement] = []
        collectLists(dockApp, into: &lists)
        var hit: String = "없음"
        for list in lists {
            for item in children(list) where frame(item).contains(point) {
                hit = "\(describe(item, kAXTitleAttribute as String)) frame=\(frame(item))"
            }
        }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
        print("클릭 \(point) → 아이콘: \(hit) | 프론트모스트: \(front)")
    }
}
```

그리고 파일 맨 끝에 다음을 추가한다.

```swift
if CommandLine.arguments.contains("watch") {
    let watcher = ClickWatcher(dockApp: dockApp)
    watcher.start()
    CFRunLoopRun()
}
```

`dump` 출력이 매번 나오지 않도록, `=== 트리 (깊이 3) ===`부터 `=== 화면 ===` 블록 전체를 다음으로 감싼다.

```swift
if !CommandLine.arguments.contains("watch") {
    // ... 기존 dump 출력 블록 ...
}
```

- [ ] **Step 2: watch 모드 실행**

Run: `swift run DockProbe watch`
Expected: `클릭을 관찰합니다.`

- [ ] **Step 3: 좌표계 검증**

Dock의 아무 앱 아이콘이나 클릭한다.
Expected: `아이콘: <앱 이름> frame=...`이 출력된다.

`아이콘: 없음`이 계속 나오면 AX 좌표와 `CGEvent.location`의 원점이 다르다는 뜻이다. 그 경우 `frame(item)`의 y값과 클릭 좌표의 y값을 비교해 변환식을 찾아 findings 문서에 기록한다.

- [ ] **Step 4: Plan A / Plan B 판정**

**판정의 핵심은 "윈도우가 전부 보이는 앱"이 아니라 "윈도우가 이미 최소화된 앱"이다.** 리슨 전용 탭에서는 클릭이 Dock에 그대로 전달되므로, 그 상태에서 Dock이 윈도우를 복원한다면 우리의 비동기 최소화와 Dock의 복원이 서로 경쟁하는 플립플롭이 생긴다. 아래 세 가지 상태를 모두 확인해야 판정이 성립한다.

메모 앱으로 다음을 각각 수행하고 화면에서 무슨 일이 일어나는지 findings 문서에 기록한다.

| # | 상태 | 만드는 방법 | 관찰할 것 |
|---|---|---|---|
| 1 | 모든 윈도우가 보임, 프론트모스트 | 메모를 활성화 | 아무 일도 없는가 |
| 2 | **모든 윈도우가 최소화됨, 프론트모스트** | 윈도우 하나만 열고 ⌘M, 메모가 여전히 프론트모스트인지 확인 | **Dock이 윈도우를 복원하는가** |
| 3 | 일부만 최소화됨, 프론트모스트 | 윈도우 2개를 열고 하나만 ⌘M | Dock이 최소화된 것을 복원하는가 |

판정:

- 1·2·3 모두에서 아무 일도 일어나지 않는다 → **Plan A**. 리슨 전용 탭으로 충분하다
- 2 또는 3에서 Dock이 복원한다 → **Plan B**. 액티브 탭으로 `.minimize` 판정 시 클릭을 삼켜야 한다. 그렇지 않으면 우리가 최소화하는 동안 Dock이 복원해 화면이 깜빡인다
- 1에서 윈도우가 앞으로 나오는 등의 동작이 있다 → **Plan B**

- [ ] **Step 5: Dock 확대 검증 — 이 계획에서 가장 위험한 미지수**

AX 프레임이 확대를 실시간 반영한다면 1초 주기 캐시는 "약간 낡은" 것이 아니라 **매 클릭마다 틀린다.** 그렇다고 콜백에서 AX를 조회할 수도 없다(그것이 이 프로젝트의 최우선 금지 사항이다). 그래서 어느 쪽인지에 따라 대응이 완전히 달라진다.

판별 방법: watch 모드를 실행한 상태에서, 시스템 설정 > 데스크탑 및 Dock 에서 **확대를 켜고** 아래 두 값을 비교한다.

1. 커서를 Dock에서 멀리 둔 상태에서 `swift run DockProbe`로 특정 아이콘의 frame을 기록
2. watch 모드에서 그 아이콘 위에 커서를 올린 채 클릭했을 때 출력되는 frame을 기록

- **Case A — 두 frame이 다르다 (AX가 확대를 실시간 반영)**
  → 캐시 갱신을 커서 위치에 연동한다. 이벤트 탭 마스크에 `mouseMoved`를 추가하되 **콜백은 "커서가 Dock 영역 안에 있다"는 타임스탬프만 기록**하고 AX는 건드리지 않는다. `DockIndex`는 그 타임스탬프가 최근이면 갱신 주기를 30ms로 올리고, 아니면 1초로 되돌린다. 클릭 시점의 캐시가 30ms 이내가 되어 확대 상태에서도 정확해진다.
- **Case B — 두 frame이 같다 (AX가 정적 레이아웃 기준)**
  → 확대가 켜지면 아이콘이 시각적으로 퍼지므로 사용자가 클릭한 좌표와 정적 프레임이 어긋나 오탐이 난다. 확대가 켜져 있는 동안에는 기능을 끈다. `UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "magnification")`으로 감지하고, 메뉴바에 "Dock 확대가 켜져 있어 일시 중지됨"을 표시한다.

어느 Case인지 findings 문서에 명시한다. Task 10이 이 결과를 읽는다. 검증 후 확대 설정은 원래대로 되돌린다.

- [ ] **Step 6: Dock 배치 변형 검증**

Dock 위치를 왼쪽으로 옮기고, 자동 숨김을 켜고 각각 watch 모드로 클릭이 올바르게 매칭되는지 확인한다. 결과를 기록하고 설정을 원복한다.

- [ ] **Step 7: findings 문서 갱신 후 커밋**

```bash
git add -A
git commit -m "feat: Phase 0 좌표계·클릭 동작·Dock 확대 실측"
```

- [ ] **Step 8: 게이트 확인**

findings 문서에 다음 4가지 답이 모두 적혀 있어야 다음 Phase로 넘어간다.

1. AXList 개수와 순회 방법
2. bundleID를 얻는 방법 (`AXURL` 또는 교차 조회)
3. 좌표 변환식 (없으면 "그대로 사용")
4. Plan A / Plan B 판정 — Step 4의 상태 1·2·3 각각의 관찰 결과와 함께
5. Dock 확대 Case A / Case B 판정

---

# Phase 1 — 스캐폴딩과 서명 파이프라인

**로직보다 먼저 한다.** 접근성 권한은 코드 서명과 번들 ID에 묶이므로, 서명이 불안정하면 이후 모든 디버깅이 "권한이 날아간 것인지 코드가 틀린 것인지" 구분되지 않는다.

## Task 3: Info.plist와 앱 번들 조립

**Files:**
- Create: `Resources/Info.plist`
- Create: `Scripts/bundle.sh`

- [ ] **Step 1: `Resources/Info.plist` 작성**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleExecutable</key>
    <string>DockMinimizer</string>
    <key>CFBundleIdentifier</key>
    <string>com.changhun.dockminimizer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DockMinimizer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 changhun</string>
</dict>
</plist>
```

`LSUIElement`가 `true`이므로 이 앱 자신은 Dock 아이콘을 갖지 않는다. 자기 자신을 최소화하는 사고가 구조적으로 불가능해진다.

- [ ] **Step 2: `Scripts/bundle.sh` 작성**

```bash
#!/usr/bin/env bash
# .app 번들을 조립하고 서명한다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_NAME="${DOCKMINIMIZER_CERT:-DockMinimizer Self Signed}"
APP="$ROOT/build/DockMinimizer.app"

echo "==> 릴리스 빌드"
swift build -c release --package-path "$ROOT" --product DockMinimizer
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

echo "==> 번들 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DockMinimizer" "$APP/Contents/MacOS/DockMinimizer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "==> 서명: $CERT_NAME"
    codesign --force --sign "$CERT_NAME" "$APP"
else
    echo "경고: '$CERT_NAME' 인증서가 없습니다. Scripts/make-cert.sh 를 먼저 실행하세요."
    echo "      임시로 ad-hoc 서명합니다. 재빌드 때마다 접근성 권한이 사라집니다."
    codesign --force --sign - "$APP"
fi

codesign --verify --verbose=2 "$APP"
echo "==> 완료: $APP"
```

- [ ] **Step 3: 실행 권한 부여 후 실행**

Run: `chmod +x Scripts/bundle.sh && ./Scripts/bundle.sh`
Expected: `==> 완료: .../build/DockMinimizer.app` (인증서 경고는 아직 정상)

- [ ] **Step 4: 번들 구조 확인**

Run: `find build/DockMinimizer.app -type f`
Expected:
```
build/DockMinimizer.app/Contents/Info.plist
build/DockMinimizer.app/Contents/MacOS/DockMinimizer
build/DockMinimizer.app/Contents/_CodeSignature/CodeResources
```

- [ ] **Step 5: 커밋**

```bash
git add -A
git commit -m "feat: Info.plist와 앱 번들 조립 스크립트"
```

## Task 4: 고정 코드서명 인증서

**Files:**
- Create: `Scripts/make-cert.sh`

- [ ] **Step 1: `Scripts/make-cert.sh` 작성**

```bash
#!/usr/bin/env bash
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

# 빈 암호로 내보내면 macOS security가 MAC 검증에 실패한다
# ("SecKeychainItemImport: MAC verification failed during PKCS12 import").
# LibreSSL 3.3.6에서 실제로 재현됨. 임시 암호를 쓰면 통과한다.
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
```

- [ ] **Step 2: 실행**

Run: `chmod +x Scripts/make-cert.sh && ./Scripts/make-cert.sh`
Expected: 마지막 줄에 `1) <해시> "DockMinimizer Self Signed"` 형태로 인증서가 나열된다.

키체인 암호 입력창이 뜨면 로그인 암호를 입력한다. 이는 1회성 단계다.

- [ ] **Step 3: 실패 시 GUI 대안**

`security find-identity`에 인증서가 나타나지 않으면 GUI로 만든다.

키체인 접근 앱 실행 → 메뉴의 인증서 지원 > 인증서 생성 → 이름 `DockMinimizer Self Signed`, 신원 유형 `자체 서명 루트`, 인증서 유형 **`코드 서명`**, "기본값 무시" 체크 해제 → 생성. 그 후 Step 2의 확인 명령을 다시 실행한다.

- [ ] **Step 4: 서명된 번들 재생성**

Run: `./Scripts/bundle.sh`
Expected: `==> 서명: DockMinimizer Self Signed` 가 출력되고 인증서 경고가 사라진다.

- [ ] **Step 5: 서명 주체 확인**

Run: `codesign -dv --verbose=4 build/DockMinimizer.app 2>&1 | grep -E 'Identifier|Authority'`
Expected:
```
Identifier=com.changhun.dockminimizer
Authority=DockMinimizer Self Signed
```

- [ ] **Step 6: 커밋**

```bash
git add -A
git commit -m "feat: 고정 self-signed 코드서명 인증서 생성 스크립트"
```

## Task 5: 메뉴바 껍데기와 설치

**Files:**
- Modify: `Sources/DockMinimizer/main.swift`
- Create: `Sources/DockMinimizer/AppDelegate.swift`
- Create: `Sources/DockMinimizer/MenuBarController.swift`
- Create: `Scripts/install.sh`

- [ ] **Step 1: `Sources/DockMinimizer/MenuBarController.swift` 작성**

```swift
import AppKit

/// 메뉴바 아이콘과 메뉴를 소유한다. Task 17에서 항목이 추가된다.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "dock.arrow.down.rectangle",
            accessibilityDescription: "DockMinimizer"
        )
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(
            title: "종료",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }
}
```

- [ ] **Step 2: `Sources/DockMinimizer/AppDelegate.swift` 작성**

```swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
    }
}
```

- [ ] **Step 3: `Sources/DockMinimizer/main.swift` 교체**

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement와 짝을 이룬다. Dock 아이콘도 메뉴바 앱 메뉴도 갖지 않는다.
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: `Scripts/install.sh` 작성**

```bash
#!/usr/bin/env bash
# /Applications 고정 경로에 설치한다.
# 경로가 바뀌면 접근성 권한이 사라지므로 항상 같은 경로를 쓴다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/Applications/DockMinimizer.app"

"$ROOT/Scripts/bundle.sh"

echo "==> 실행 중인 인스턴스 종료"
pkill -x DockMinimizer 2>/dev/null || true
sleep 1

echo "==> 설치: $DEST"
rm -rf "$DEST"
cp -R "$ROOT/build/DockMinimizer.app" "$DEST"

echo "==> 실행"
open "$DEST"
echo "완료."
```

- [ ] **Step 5: 설치**

Run: `chmod +x Scripts/install.sh && ./Scripts/install.sh`
Expected: `완료.` 그리고 메뉴바 오른쪽에 아이콘이 나타난다.

- [ ] **Step 6: 육안 확인**

메뉴바 아이콘을 클릭해 "종료" 메뉴가 나오는지 확인한다. Dock에는 이 앱의 아이콘이 **나타나지 않아야** 한다.

- [ ] **Step 7: 접근성 권한 부여**

시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용 에서 `+` 버튼으로 `/Applications/DockMinimizer.app`을 추가하고 켠다.

- [ ] **Step 8: 재빌드 후에도 권한이 유지되는지 확인 (서명 파이프라인의 핵심 검증)**

Run: `./Scripts/install.sh`

그 후 시스템 설정 > 손쉬운 사용 목록에서 DockMinimizer가 **여전히 켜져 있는지** 확인한다. 꺼져 있거나 사라졌다면 서명이 불안정한 것이므로 Task 4로 돌아간다. 이 검증을 통과해야 Phase 2로 넘어간다.

- [ ] **Step 9: 커밋**

```bash
git add -A
git commit -m "feat: 메뉴바 껍데기와 설치 스크립트"
```

---

# Phase 2 — 핵심 로직

## Task 6: Core 값 타입과 히트테스트

**Files:**
- Delete: `Sources/DockMinimizerCore/Placeholder.swift`
- Delete: `Tests/DockMinimizerCoreTests/PlaceholderTests.swift`
- Create: `Sources/DockMinimizerCore/DockSnapshot.swift`
- Create: `Sources/DockMinimizerCore/AppState.swift`
- Test: `Tests/DockMinimizerCoreTests/DockSnapshotTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/DockMinimizerCoreTests/DockSnapshotTests.swift`:

```swift
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
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter DockSnapshotTests`
Expected: FAIL — `cannot find 'DockItem' in scope`

- [ ] **Step 3: 스텁 파일 삭제**

```bash
rm Sources/DockMinimizerCore/Placeholder.swift Tests/DockMinimizerCoreTests/PlaceholderTests.swift
```

- [ ] **Step 4: `Sources/DockMinimizerCore/DockSnapshot.swift` 작성**

```swift
import CoreGraphics
import Foundation

/// Dock에 표시된 아이콘 하나. AX 트리에서 읽어 온 스냅샷 값이며 갱신 시점에 통째로 교체된다.
public struct DockItem: Equatable, Sendable {
    /// 전역 디스플레이 좌표. `CGEvent.location`과 같은 공간이어야 한다.
    public let frame: CGRect
    public let bundleID: String?
    public let title: String?

    public init(frame: CGRect, bundleID: String?, title: String?) {
        self.frame = frame
        self.bundleID = bundleID
        self.title = title
    }
}

/// 특정 시점의 Dock 아이콘 배치. 불변이므로 이벤트 탭 콜백에서 락 없이 읽을 수 있다.
public struct DockSnapshot: Equatable, Sendable {
    public let items: [DockItem]

    public static let empty = DockSnapshot(items: [])

    public init(items: [DockItem]) {
        self.items = items
    }

    /// 주어진 좌표를 포함하는 첫 아이콘. `CGRect.contains`는 왼쪽·위쪽 경계를
    /// 포함하고 오른쪽·아래쪽 경계를 제외하므로 인접 아이콘이 중복 매칭되지 않는다.
    public func item(at point: CGPoint) -> DockItem? {
        items.first { $0.frame.contains(point) }
    }
}
```

- [ ] **Step 5: `Sources/DockMinimizerCore/AppState.swift` 작성**

```swift
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
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `swift test --filter DockSnapshotTests`
Expected: PASS — 6 tests passed

- [ ] **Step 7: 커밋**

```bash
git add -A
git commit -m "feat: DockSnapshot 히트테스트와 Core 값 타입"
```

## Task 7: ClickRouter 판정 로직

앱의 모든 판정이 여기 모인다. AX도 CGEvent도 건드리지 않는 순수 함수이므로 전 분기를 테스트로 고정한다.

**Phase 0 실측 반영:** Dock은 프론트모스트 앱을 복원하지 않는다(`2026-07-30-phase0-findings.md` §5). 따라서 당초의 `.letThrough`(Dock 기본 복원에 맡김)는 성립하지 않고, 복원도 우리가 수행하는 `.restore`가 된다. 판정은 3분기다.

**Files:**
- Create: `Sources/DockMinimizerCore/ClickRouter.swift`
- Test: `Tests/DockMinimizerCoreTests/ClickRouterTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/DockMinimizerCoreTests/ClickRouterTests.swift`:

```swift
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
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter ClickRouterTests`
Expected: FAIL — `cannot find 'ClickRouter' in scope`

- [ ] **Step 3: `Sources/DockMinimizerCore/ClickRouter.swift` 작성**

```swift
import CoreGraphics
import Foundation

/// 수정자 키. CGEventFlags를 그대로 쓰지 않는 이유는 Core를 CoreGraphics 이벤트
/// API에서 분리해 테스트하기 쉽게 만들기 위함이다. 변환은 EventTapController가 한다.
public struct ClickModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ClickModifiers(rawValue: 1 << 0)
    public static let option = ClickModifiers(rawValue: 1 << 1)
    public static let control = ClickModifiers(rawValue: 1 << 2)
    public static let shift = ClickModifiers(rawValue: 1 << 3)
}

public struct RouterInput: Sendable {
    public let point: CGPoint
    public let modifiers: ClickModifiers
    public let snapshot: DockSnapshot
    public let frontmost: AppState?
    public let isEnabled: Bool
    public let excludedBundleIDs: Set<String>

    public init(
        point: CGPoint,
        modifiers: ClickModifiers,
        snapshot: DockSnapshot,
        frontmost: AppState?,
        isEnabled: Bool,
        excludedBundleIDs: Set<String>
    ) {
        self.point = point
        self.modifiers = modifiers
        self.snapshot = snapshot
        self.frontmost = frontmost
        self.isEnabled = isEnabled
        self.excludedBundleIDs = excludedBundleIDs
    }
}

public enum Decision: Equatable, Sendable {
    /// 우리 관심사가 아니다. 아무 것도 하지 않는다.
    case ignore
    case minimize(pid: pid_t)
    /// Dock은 프론트모스트 앱을 복원하지 않으므로 우리가 직접 복원한다.
    case restore(pid: pid_t)
}

/// 앱의 모든 판정이 모이는 순수 함수. AX도 CGEvent도 호출하지 않으므로
/// 이벤트 탭 콜백에서 안전하게 실행되고, 전 분기를 단위 테스트로 고정할 수 있다.
public enum ClickRouter {
    public static func decide(_ input: RouterInput) -> Decision {
        guard input.isEnabled else { return .ignore }

        // 우클릭 메뉴, ⌘클릭(Finder에서 보기), 옵션클릭 등 기존 동작을 건드리지 않는다.
        guard input.modifiers.isEmpty else { return .ignore }

        guard let item = input.snapshot.item(at: input.point) else { return .ignore }

        // 휴지통, 스택, 구분선처럼 앱이 아닌 항목.
        guard let bundleID = item.bundleID else { return .ignore }

        guard !input.excludedBundleIDs.contains(bundleID) else { return .ignore }

        // 프론트모스트가 아닌 앱은 Dock이 알아서 활성화하고 복원한다 (Phase 0 상태 4).
        guard let front = input.frontmost, front.bundleID == bundleID else { return .ignore }

        // 보이는 윈도우가 하나라도 있으면 그것들을 최소화한다.
        if front.hasVisibleWindows { return .minimize(pid: front.pid) }

        // 전부 최소화된 상태. Dock은 이 상태의 프론트모스트 앱을 복원하지 않는다.
        if front.hasMinimizedWindows { return .restore(pid: front.pid) }

        // 윈도우가 아예 없는 앱(메뉴바 전용 등). 최소화할 것도 복원할 것도 없다.
        return .ignore
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ClickRouterTests`
Expected: PASS — 12 tests passed

- [ ] **Step 5: 커밋**

```bash
git add -A
git commit -m "feat: ClickRouter 3분기 판정 로직"
```

## Task 8: 설정 모델

**Files:**
- Create: `Sources/DockMinimizerCore/Settings.swift`
- Test: `Tests/DockMinimizerCoreTests/SettingsTests.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/DockMinimizerCoreTests/SettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import DockMinimizerCore

private func makeDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test("기본값은 활성 상태다")
func defaultsToEnabled() {
    let settings = Settings(defaults: makeDefaults("test.enabled"))
    #expect(settings.isEnabled)
}

@Test("Finder와 자기 자신은 항상 제외된다")
func alwaysExcludesFinderAndSelf() {
    let settings = Settings(defaults: makeDefaults("test.builtin"))
    #expect(settings.excludedBundleIDs.contains("com.apple.finder"))
    #expect(settings.excludedBundleIDs.contains("com.changhun.dockminimizer"))
}

@Test("사용자가 추가한 제외 앱이 목록에 합쳐진다")
func mergesUserExclusions() {
    let settings = Settings(defaults: makeDefaults("test.merge"))
    settings.addExclusion("com.apple.Safari")
    #expect(settings.excludedBundleIDs.contains("com.apple.Safari"))
    #expect(settings.excludedBundleIDs.contains("com.apple.finder"))
}

@Test("사용자 제외 앱을 제거할 수 있다")
func removesUserExclusions() {
    let settings = Settings(defaults: makeDefaults("test.remove"))
    settings.addExclusion("com.apple.Safari")
    settings.removeExclusion("com.apple.Safari")
    #expect(!settings.excludedBundleIDs.contains("com.apple.Safari"))
}

@Test("고정 제외 앱은 제거되지 않는다")
func cannotRemoveBuiltinExclusions() {
    let settings = Settings(defaults: makeDefaults("test.pinned"))
    settings.removeExclusion("com.apple.finder")
    #expect(settings.excludedBundleIDs.contains("com.apple.finder"))
}

@Test("설정이 영속화된다")
func persistsAcrossInstances() {
    let defaults = makeDefaults("test.persist")
    let first = Settings(defaults: defaults)
    first.isEnabled = false
    first.addExclusion("com.apple.Safari")

    let second = Settings(defaults: defaults)
    #expect(!second.isEnabled)
    #expect(second.userExcludedBundleIDs.contains("com.apple.Safari"))
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter SettingsTests`
Expected: FAIL — `cannot find 'Settings' in scope`

- [ ] **Step 3: `Sources/DockMinimizerCore/Settings.swift` 작성**

```swift
import Foundation

/// UserDefaults 기반 설정. 읽기는 이벤트 탭 콜백 밖(Coordinator의 캐시 갱신 시점)에서만 하고,
/// 콜백에는 스냅샷된 값을 넘긴다.
public final class Settings: @unchecked Sendable {
    /// 사용자가 제거할 수 없는 제외 목록.
    /// Finder는 Dock 동작이 특수하고, 자기 자신은 LSUIElement라 아이콘조차 없다.
    public static let pinnedExclusions: Set<String> = [
        "com.apple.finder",
        "com.changhun.dockminimizer",
    ]

    private enum Key {
        static let isEnabled = "isEnabled"
        static let userExclusions = "userExcludedBundleIDs"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.isEnabled: true])
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled) }
        set { defaults.set(newValue, forKey: Key.isEnabled) }
    }

    public var userExcludedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.userExclusions) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.userExclusions) }
    }

    /// 판정에 실제로 쓰이는 최종 제외 목록.
    public var excludedBundleIDs: Set<String> {
        Settings.pinnedExclusions.union(userExcludedBundleIDs)
    }

    public func addExclusion(_ bundleID: String) {
        userExcludedBundleIDs.insert(bundleID)
    }

    public func removeExclusion(_ bundleID: String) {
        userExcludedBundleIDs.remove(bundleID)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter SettingsTests`
Expected: PASS — 6 tests passed

- [ ] **Step 5: 전체 테스트 실행**

Run: `swift test`
Expected: PASS — 24 tests passed

- [ ] **Step 6: 커밋**

```bash
git add -A
git commit -m "feat: 설정 모델과 제외 목록"
```

## Task 9: AX 헬퍼

**Files:**
- Create: `Sources/DockMinimizer/AXHelpers.swift`

- [ ] **Step 1: `Sources/DockMinimizer/AXHelpers.swift` 작성**

```swift
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
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: 커밋**

```bash
git add -A
git commit -m "feat: AX API 래퍼"
```

## Task 10: DockIndex 캐시

**Phase 0 실측 반영** (`2026-07-30-phase0-findings.md`):

- `AXList`는 1개지만 재귀 수집을 유지한다 (구조 변경 대비 비용이 거의 없다)
- **`subrole == "AXApplicationDockItem"`으로 먼저 걸러야 한다.** 폴더 항목도 `AXURL`을 가지므로 "bundleID가 nil이면 앱이 아니다"에만 의존하면 위험하다
- 좌표 변환은 불필요하다
- 확대는 **Case B**(AX 프레임이 정적). 확대가 켜진 동안에는 기능을 일시 중지한다
- **최소화는 Dock의 폭을 바꾼다.** 최소화된 윈도우가 별도 아이콘으로 추가되고 Dock이 가운데 정렬을 다시 하므로 모든 아이콘의 x좌표가 약 22pt 밀린다. 이 변화는 어떤 알림으로도 통보되지 않으므로 우리 동작 직후 직접 갱신해야 한다

**Files:**
- Create: `Sources/DockMinimizer/DockIndex.swift`

- [ ] **Step 1: `Sources/DockMinimizer/DockIndex.swift` 작성**

```swift
import AppKit
import ApplicationServices
import DockMinimizerCore
import os

/// Dock의 AX 트리를 주기적으로 읽어 불변 스냅샷으로 캐싱한다.
///
/// 이 클래스의 존재 이유가 곧 이 프로젝트의 최우선 제약이다. Dock AX 조회는 수십 밀리초가
/// 걸리는 크로스 프로세스 IPC이고, 이벤트 탭 콜백에서 그만큼 지연되면 macOS가
/// kCGEventTapDisabledByTimeout으로 탭을 조용히 죽인다. 그래서 모든 AX 조회를
/// 전용 시리얼 큐에서 미리 수행하고, 콜백은 `snapshot`만 읽는다.
final class DockIndex: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.changhun.dockminimizer.dockindex")
    private let storage = OSAllocatedUnfairLock(initialState: DockSnapshot.empty)
    private var bundleIDCache: [URL: String] = [:]
    private var refreshTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    /// Dock 확대가 켜져 있는가.
    ///
    /// 실측 결과 AX 프레임은 확대의 영향을 받지 않는다(Case B). 확대 중에는 아이콘이
    /// 시각적으로 커지고 이웃이 밀려나므로 사용자가 클릭한 좌표와 정적 프레임이
    /// 어긋날 수 있고, 그 어긋남의 크기는 측정하지 못했다. 오작동보다 일시 중지가 낫다.
    static var isDockMagnificationEnabled: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "magnification") ?? false
    }

    /// 이벤트 탭 콜백이 호출하는 유일한 메서드. 락 획득과 배열 참조 복사만 한다.
    var snapshot: DockSnapshot {
        storage.withLock { $0 }
    }

    func start() {
        registerObservers()
        startTimer()
        refresh()
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    func refresh() {
        queue.async { [weak self] in
            self?.rebuild()
        }
    }

    /// 우리가 최소화·복원한 직후에 호출한다.
    ///
    /// 최소화된 윈도우는 Dock에 별도 아이콘으로 추가되고, Dock은 가운데 정렬이므로
    /// 폭이 바뀌면 **모든 앱 아이콘의 x좌표가 밀린다.** 갱신하지 않으면 다음 클릭이
    /// 이웃 앱을 최소화한다. 지니 애니메이션이 진행 중일 수 있으므로 즉시 한 번,
    /// 애니메이션이 끝난 뒤 한 번 더 읽는다.
    func refreshAfterWindowChange() {
        refresh()
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.rebuild()
        }
    }

    // MARK: - 갱신 트리거

    private func registerObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceNotifications: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in workspaceNotifications {
            observers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                self?.refresh()
            })
        }

        // 해상도 변경이나 디스플레이 연결 시 Dock 아이콘 좌표가 통째로 바뀐다.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.refresh()
        })
    }

    /// 안전망. 위 알림으로 잡히지 않는 변화(Dock 설정 변경, Dock 재시작, 아이콘 재배열)를
    /// 흡수한다. 아이콘 30여 개의 AX 순회는 백그라운드에서 충분히 가볍다.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.rebuild()
        }
        timer.resume()
        refreshTimer = timer
    }

    // MARK: - AX 조회 (반드시 queue 위에서만 실행)

    private func rebuild() {
        let fresh = buildSnapshot()
        storage.withLock { $0 = fresh }
    }

    private func buildSnapshot() -> DockSnapshot {
        // 빈 스냅샷이면 ClickRouter가 자연히 .ignore를 낸다. 별도 분기가 필요 없다.
        guard !Self.isDockMagnificationEnabled else { return .empty }

        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return .empty
        }
        // Dock이 재시작되면 pid가 바뀌지만, 매번 새로 조회하므로 자동으로 따라간다.
        let dockElement = AX.application(pid: dock.processIdentifier)

        var lists: [AXUIElement] = []
        collectLists(dockElement, depth: 0, into: &lists)

        var items: [DockItem] = []
        for list in lists {
            for element in AX.children(list) {
                // 구분선, 폴더, 최소화된 윈도우, 휴지통을 여기서 배제한다.
                // 폴더 항목도 AXURL을 가지므로 bundleID 판정만으로는 걸러지지 않는다.
                guard AX.string(element, kAXSubroleAttribute as String)
                    == "AXApplicationDockItem" else { continue }
                guard let frame = AX.frame(element), frame.width > 0, frame.height > 0 else {
                    continue
                }
                items.append(DockItem(
                    frame: frame,
                    bundleID: bundleID(of: element),
                    title: AX.string(element, kAXTitleAttribute as String)
                ))
            }
        }
        return DockSnapshot(items: items)
    }

    /// 실측에서는 AXList가 1개였지만, 구조가 바뀌어도 따라가도록 재귀로 수집한다.
    private func collectLists(_ element: AXUIElement, depth: Int, into result: inout [AXUIElement]) {
        guard depth <= 6 else { return }
        if AX.string(element, kAXRoleAttribute as String) == "AXList" {
            result.append(element)
        }
        for child in AX.children(element) {
            collectLists(child, depth: depth + 1, into: &result)
        }
    }

    /// `Bundle(url:)`은 디스크 I/O이므로 URL 기준으로 캐싱한다.
    private func bundleID(of element: AXUIElement) -> String? {
        guard let url = AX.url(element, "AXURL") else { return nil }
        if let cached = bundleIDCache[url] { return cached }
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
        bundleIDCache[url] = identifier
        return identifier
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: 커밋**

```bash
git add -A
git commit -m "feat: DockIndex — Dock AX 트리 스냅샷 캐시"
```

## Task 11: AppStateCache

**Phase 0 실측 반영:** 최소화하면 윈도우의 subrole이 `AXStandardWindow`에서 `AXDialog`로 바뀐다. subrole로 필터하면 최소화된 윈도우가 목록에서 사라진 것처럼 보이고 복원 대상을 찾지 못한다. `AXMinimized` 속성 보유를 기준으로 삼고, 최소화 대상이 아닌 subrole만 제외한다.

**Files:**
- Create: `Sources/DockMinimizer/AppStateCache.swift`

- [ ] **Step 1: `Sources/DockMinimizer/AppStateCache.swift` 작성**

```swift
import AppKit
import ApplicationServices
import DockMinimizerCore
import os

/// 프론트모스트 앱의 윈도우 상태를 캐싱한다.
///
/// DockIndex와 같은 이유로 존재한다. `NSWorkspace.frontmostApplication`과 윈도우 목록
/// 조회는 모두 IPC일 수 있으므로 이벤트 탭 콜백에서 호출하지 않고 여기서 미리 계산해 둔다.
final class AppStateCache: @unchecked Sendable {
    private struct State: Sendable {
        var frontmost: AppState?
        /// 이 시각까지는 타이머 갱신이 캐시를 덮어쓰지 않는다.
        var settleUntil: UInt64 = 0
    }

    /// 우리가 최소화·복원한 직후 AX가 아직 이전 상태를 보고할 수 있다. 그 사이 타이머가
    /// 캐시를 되돌리면 다음 클릭이 같은 방향으로 다시 동작한다(토글이 한쪽으로 죽는다).
    /// 동작 직후 이 시간만큼 타이머 갱신을 막는다.
    private static let settleDuration: UInt64 = 800_000_000  // 800ms

    private let queue = DispatchQueue(label: "com.changhun.dockminimizer.appstate")
    private let storage = OSAllocatedUnfairLock(initialState: State())
    private var refreshTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    /// 이벤트 탭 콜백이 읽는 값.
    var frontmost: AppState? {
        storage.withLock { $0.frontmost }
    }

    func start() {
        registerObservers()
        startTimer()
        refresh()
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// 최소화를 수행한 직후 호출한다.
    func markMinimized(pid: pid_t) {
        apply(pid: pid, hasVisibleWindows: false, hasMinimizedWindows: true)
    }

    /// 복원을 수행한 직후 호출한다. markMinimized와 대칭이어야 한다.
    /// 이 짝이 없으면 복원 후에도 캐시가 "보이는 윈도우 없음"으로 남아
    /// 다음 클릭이 다시 .restore로 판정되고 아무 일도 일어나지 않는다.
    func markRestored(pid: pid_t) {
        apply(pid: pid, hasVisibleWindows: true, hasMinimizedWindows: false)
    }

    private func apply(pid: pid_t, hasVisibleWindows: Bool, hasMinimizedWindows: Bool) {
        storage.withLock { state in
            guard let front = state.frontmost, front.pid == pid else { return }
            state.frontmost = AppState(
                pid: front.pid,
                bundleID: front.bundleID,
                hasVisibleWindows: hasVisibleWindows,
                hasMinimizedWindows: hasMinimizedWindows
            )
            state.settleUntil = DispatchTime.now().uptimeNanoseconds + Self.settleDuration
        }
    }

    // MARK: - 갱신

    private func registerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    /// 사용자가 ⌘M, ⌘Tab, Mission Control로 윈도우 상태를 바꾸면 알림이 오지 않으므로
    /// 짧은 주기로 실제 상태를 다시 읽는다. 앱 하나의 윈도우 목록 조회라 비용이 작다.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.performRefresh()
        }
        timer.resume()
        refreshTimer = timer
    }

    private func refresh() {
        queue.async { [weak self] in
            self?.performRefresh()
        }
    }

    private func performRefresh() {
        // 정착 구간 중에는 우리가 방금 넣은 값을 신뢰한다.
        let settling = storage.withLock {
            DispatchTime.now().uptimeNanoseconds < $0.settleUntil
        }
        guard !settling else { return }

        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            storage.withLock { $0.frontmost = nil }
            return
        }
        let pid = app.processIdentifier
        let counts = WindowController.windowCounts(pid: pid)

        storage.withLock { state in
            state.frontmost = AppState(
                pid: pid,
                bundleID: bundleID,
                hasVisibleWindows: counts.visible > 0,
                hasMinimizedWindows: counts.minimized > 0
            )
        }
    }
}
```

- [ ] **Step 2: 빌드 확인 (Task 12 이후)**

`WindowController`가 아직 없으므로 Task 12까지는 빌드가 실패한다. 두 작업을 연속으로 진행한다.

## Task 12: WindowController — 최소화와 복원

Dock은 프론트모스트 앱을 복원하지 않으므로(Phase 0 §5) 복원도 우리가 수행한다. 최소화와 복원이 같은 술어를 공유해야 하므로 한 타입에 둔다.

**Files:**
- Create: `Sources/DockMinimizer/WindowController.swift`

- [ ] **Step 1: `Sources/DockMinimizer/WindowController.swift` 작성**

```swift
import AppKit
import ApplicationServices

/// 대상 앱 윈도우의 최소화 상태를 읽고 바꾼다. AX 호출이므로 백그라운드 큐에서만 실행한다.
enum WindowController {
    /// 최소화 대상에서 제외할 subrole.
    ///
    /// `kAXStandardWindowSubrole`로 **거르면 안 된다.** 실측 결과 윈도우를 최소화하면
    /// subrole이 AXStandardWindow에서 AXDialog로 바뀌므로, 그렇게 거르면 최소화된 윈도우가
    /// 목록에서 사라진 것처럼 보이고 복원 대상을 찾지 못한다.
    /// 대신 AXMinimized 속성을 가진 윈도우를 대상으로 하고 시트류만 제외한다.
    private static let excludedSubroles: Set<String> = [
        "AXSheet",
        "AXSystemDialog",
        "AXSystemFloatingWindow",
    ]

    /// (윈도우, 현재 최소화 여부) 목록.
    private static func targets(pid: pid_t) -> [(window: AXUIElement, minimized: Bool)] {
        let app = AX.application(pid: pid)
        var result: [(AXUIElement, Bool)] = []
        for window in AX.windows(app) {
            let subrole = AX.string(window, kAXSubroleAttribute as String) ?? ""
            guard !excludedSubroles.contains(subrole) else { continue }
            // AXMinimized 속성이 없는 윈도우는 최소화 대상이 아니다.
            guard let minimized = AX.bool(window, kAXMinimizedAttribute as String) else { continue }
            // 풀스크린 윈도우는 최소화할 수 없다. 시도하면 실패하거나 이상 동작을 한다.
            if AX.bool(window, "AXFullScreen") == true { continue }
            result.append((window, minimized))
        }
        return result
    }

    /// AppStateCache가 3분기 판정에 쓰는 값.
    static func windowCounts(pid: pid_t) -> (visible: Int, minimized: Int) {
        let all = targets(pid: pid)
        let minimized = all.filter(\.minimized).count
        return (all.count - minimized, minimized)
    }

    /// 최소화한 윈도우 개수를 반환한다. 0이면 최소화할 것이 없었다는 뜻이다.
    @discardableResult
    static func minimize(pid: pid_t) -> Int {
        var count = 0
        for (window, minimized) in targets(pid: pid) where !minimized {
            if AX.setBool(window, kAXMinimizedAttribute as String, true) { count += 1 }
        }
        return count
    }

    /// 복원한 윈도우 개수를 반환한다.
    @discardableResult
    static func restore(pid: pid_t) -> Int {
        var count = 0
        for (window, minimized) in targets(pid: pid) where minimized {
            if AX.setBool(window, kAXMinimizedAttribute as String, false) { count += 1 }
        }
        return count
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: 커밋**

```bash
git add -A
git commit -m "feat: AppStateCache와 WindowController — 윈도우 상태 캐시, 최소화·복원"
```

## Task 13: EventTapController

**실측 반영 (Plan B):** Phase 0의 1차 측정은 "Dock이 혼자서 무엇을 바꾸는가"만 보았고 리슨 전용 탭으로 충분하다고 결론냈지만, **틀렸다.** 격리 실험 결과 Dock 클릭과 같은 시점에 최소화하면 Dock이 100ms 안에 원상복구한다. `.success`가 반환되고 로그도 정상이라 증상은 "아무 일도 일어나지 않음"으로만 보인다.

따라서 **액티브 탭(`.defaultTap`)으로 개입하는 클릭을 삼킨다.** mouseDown을 삼켰다면 짝이 되는 mouseUp도 반드시 삼켜야 Dock이 이상 상태에 빠지지 않는다. `.ignore`면 통과시켜 기존 Dock 동작을 그대로 둔다.

**Files:**
- Create: `Sources/DockMinimizer/EventTapController.swift`

- [ ] **Step 1: `Sources/DockMinimizer/EventTapController.swift` 작성**

```swift
import AppKit
import CoreGraphics
import DockMinimizerCore
import os

/// 이벤트 탭의 수명을 관리한다.
///
/// 두 가지 방어 장치가 들어 있다.
/// 1. 전용 스레드의 런루프에서 돌린다. 메인 스레드가 SwiftUI 렌더링 등으로 막히면
///    탭 콜백이 지연되어 macOS가 탭을 죽이기 때문이다.
/// 2. kCGEventTapDisabledByTimeout / ByUserInput을 잡아 즉시 재활성화한다.
///    이 처리가 없으면 "한동안 잘 되다가 갑자기 멈추는" 증상이 나타난다.
final class EventTapController: @unchecked Sendable {
    /// 클릭 좌표와 수정자를 받아 판정을 돌려주는 콜백. 반드시 AX 호출 없이 즉시 반환해야 한다.
    typealias Decider = (CGPoint, ClickModifiers) -> Decision
    /// 판정 결과에 따른 실제 동작. 백그라운드로 비동기 디스패치된다.
    typealias Performer = (Decision) -> Void

    private let decide: Decider
    private let perform: Performer
    private let log = Logger(subsystem: "com.changhun.dockminimizer", category: "eventtap")

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    init(decide: @escaping Decider, perform: @escaping Performer) {
        self.decide = decide
        self.perform = perform
    }

    // MARK: - 수명

    func start() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.threadRunLoop = CFRunLoopGetCurrent()
            guard self.installTap() else { return }
            CFRunLoopRun()
        }
        thread.name = "com.changhun.dockminimizer.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = threadRunLoop {
            CFRunLoopStop(runLoop)
        }
        tap = nil
        runLoopSource = nil
        thread = nil
        threadRunLoop = nil
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }

        // 리슨 전용. 클릭을 삼키지 않으므로 Dock 상호작용을 절대 깨뜨리지 않는다.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("이벤트 탭 생성 실패. 접근성 권한을 확인하세요.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        log.info("이벤트 탭 시작 (listenOnly)")
        return true
    }

    // MARK: - 콜백
    //
    // 이 아래에서는 AX API를 절대 호출하지 않는다. 캐시 읽기와 산술 연산만 한다.

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 탭이 죽었을 때의 복구. 이 처리가 없으면 앱이 조용히 무력화된다.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.error("이벤트 탭이 비활성화됨 (type=\(type.rawValue)). 재활성화합니다.")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }

        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsedMicroseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000
            // 예산을 크게 밑돌아야 정상이다. 넘어가면 캐시 밖 호출이 섞여 든 것이다.
            if elapsedMicroseconds > 2_000 {
                log.error("콜백이 느립니다: \(elapsedMicroseconds)µs")
            }
        }

        let decision = decide(event.location, Self.modifiers(from: event.flags))
        if decision != .ignore {
            perform(decision)
        }
        // 리슨 전용이므로 항상 이벤트를 그대로 통과시킨다.
        return Unmanaged.passUnretained(event)
    }

    private static func modifiers(from flags: CGEventFlags) -> ClickModifiers {
        var result: ClickModifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: 커밋**

```bash
git add -A
git commit -m "feat: EventTapController — 리슨 전용 탭, 전용 스레드, 비활성화 복구"
```

## Task 14: Coordinator 배선

**Files:**
- Create: `Sources/DockMinimizer/Coordinator.swift`
- Modify: `Sources/DockMinimizer/AppDelegate.swift`

- [ ] **Step 1: `Sources/DockMinimizer/Coordinator.swift` 작성**

```swift
import AppKit
import DockMinimizerCore
import os

/// 캐시, 판정, 실행을 잇는 조립부.
final class Coordinator: @unchecked Sendable {
    private let settings: Settings
    private let dockIndex = DockIndex()
    private let appState = AppStateCache()
    private let work = DispatchQueue(label: "com.changhun.dockminimizer.work")
    private let log = Logger(subsystem: "com.changhun.dockminimizer", category: "coordinator")

    /// 설정이 바뀔 때만 갱신되는, 콜백에서 읽기 전용으로 쓰는 스냅샷.
    private let cachedSettings = OSAllocatedUnfairLock(
        initialState: (isEnabled: true, excluded: Set<String>())
    )

    private var tapController: EventTapController?
    private var isRunning = false

    init(settings: Settings) {
        self.settings = settings
    }

    func settingsDidChange() {
        cachedSettings.withLock {
            $0 = (settings.isEnabled, settings.excludedBundleIDs)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        settingsDidChange()
        dockIndex.start()
        appState.start()

        let controller = EventTapController(
            decide: { [weak self] point, modifiers in
                guard let self else { return .ignore }
                let snapshot = self.cachedSettings.withLock { $0 }
                return ClickRouter.decide(RouterInput(
                    point: point,
                    modifiers: modifiers,
                    snapshot: self.dockIndex.snapshot,
                    frontmost: self.appState.frontmost,
                    isEnabled: snapshot.isEnabled,
                    excludedBundleIDs: snapshot.excluded
                ))
            },
            perform: { [weak self] decision in
                self?.perform(decision)
            }
        )
        controller.start()
        tapController = controller
        log.info("Coordinator 시작")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tapController?.stop()
        tapController = nil
        dockIndex.stop()
        appState.stop()
        log.info("Coordinator 중지")
    }

    /// 이벤트 탭 콜백에서 호출되지만 즉시 비동기로 빠져나간다.
    /// AX 호출은 전부 이 큐 위에서 일어난다.
    private func perform(_ decision: Decision) {
        switch decision {
        case .ignore:
            break

        case .minimize(let pid):
            work.async { [weak self] in
                guard let self else { return }
                let count = WindowController.minimize(pid: pid)
                if count > 0 {
                    self.appState.markMinimized(pid: pid)
                    // 최소화된 윈도우가 Dock에 아이콘으로 추가되면 Dock 폭이 바뀌고
                    // 모든 아이콘의 x좌표가 밀린다. 갱신하지 않으면 다음 클릭이
                    // 이웃 앱을 최소화한다.
                    self.dockIndex.refreshAfterWindowChange()
                }
                self.log.debug("최소화 pid=\(pid) 윈도우=\(count)개")
            }

        case .restore(let pid):
            work.async { [weak self] in
                guard let self else { return }
                let count = WindowController.restore(pid: pid)
                if count > 0 {
                    self.appState.markRestored(pid: pid)
                    self.dockIndex.refreshAfterWindowChange()
                }
                self.log.debug("복원 pid=\(pid) 윈도우=\(count)개")
            }
        }
    }
}
```

- [ ] **Step 2: `Sources/DockMinimizer/AppDelegate.swift` 교체**

```swift
import AppKit
import DockMinimizerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var coordinator: Coordinator?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()

        let coordinator = Coordinator(settings: settings)
        coordinator.start()
        self.coordinator = coordinator
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
```

- [ ] **Step 3: 빌드 및 설치**

Run: `swift build && ./Scripts/install.sh`
Expected: `완료.`

- [ ] **Step 4: 최소화 확인 — 이 프로젝트의 첫 성공 지점**

1. 메모 앱을 열고 윈도우를 하나 띄운다
2. 메모가 활성 상태인 것을 확인한다
3. Dock의 메모 아이콘을 클릭한다

Expected: 메모 윈도우가 지니 효과로 최소화된다.

- [ ] **Step 5: 복원 확인 — Dock은 복원하지 않으므로 우리 코드가 하는 일이다**

Dock의 메모 아이콘을 한 번 더 클릭한다.

Expected: 최소화된 윈도우가 복원된다.

복원되지 않으면 `.restore` 경로나 `markRestored`가 동작하지 않는 것이다. `log show`로 `복원 pid=... 윈도우=N개`가 찍히는지 확인한다. `윈도우=0개`면 `WindowController.targets`의 술어가 최소화된 윈도우를 놓치고 있는 것이다(subrole 필터를 다시 확인할 것).

- [ ] **Step 6: 연속 토글 확인 — 정착 구간 검증**

메모 아이콘을 **빠르게 4~6회 연속 클릭**한다.

Expected: 최소화 → 복원 → 최소화 → 복원이 매번 번갈아 일어난다. 한쪽으로 멈추면 `AppStateCache`의 정착 구간이나 `markRestored`가 빠진 것이다.

- [ ] **Step 7: 이웃 아이콘 오작동 확인 — Dock 재정렬 검증**

시스템 설정 > 데스크탑 및 Dock 에서 **"윈도우를 앱 아이콘으로 최소화"가 꺼져 있는지**(기본값) 확인한다. 이 설정에서 최소화하면 Dock에 아이콘이 추가되어 전체가 밀린다.

메모를 최소화한 **직후 곧바로** 옆에 있는 다른 앱의 아이콘을 클릭한다.

Expected: 의도한 그 앱이 활성화된다. 엉뚱한 앱이 최소화되면 `refreshAfterWindowChange`가 동작하지 않는 것이다.

- [ ] **Step 8: 비활성 앱 클릭 확인**

메모가 활성인 상태에서 Dock의 **다른** 앱 아이콘을 클릭한다.

Expected: 그 앱이 평소처럼 활성화된다. 최소화되지 않는다.

- [ ] **Step 9: 로그 확인**

Run: `log show --predicate 'subsystem == "com.changhun.dockminimizer"' --last 5m --info --debug`
Expected: `최소화`/`복원` 로그가 보이고, `콜백이 느립니다` 경고가 **없어야** 한다.

- [ ] **Step 10: 커밋**

```bash
git add -A
git commit -m "feat: Coordinator 배선 — 최소화·복원 토글 완성"
```

# Phase 3 — 설정과 편의 기능

## Task 15: 권한 관리

**Files:**
- Create: `Sources/DockMinimizer/PermissionsManager.swift`
- Modify: `Sources/DockMinimizer/AppDelegate.swift`

- [ ] **Step 1: `Sources/DockMinimizer/PermissionsManager.swift` 작성**

```swift
import AppKit
import ApplicationServices
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
```

- [ ] **Step 2: `AppDelegate`에 배선**

`Sources/DockMinimizer/AppDelegate.swift`를 다음으로 교체한다.

권한은 앱 실행 후에 부여되는 것이 정상 경로다. README의 설치 순서 자체가 "설치 → 실행 → 시스템 설정에서 허용"이므로, `isTrusted`가 false→true로 바뀌는 순간 Coordinator를 시작해야 한다. 이 구독이 없으면 앱이 켜져 있는데 아무 일도 하지 않고, 재실행해야만 동작하게 된다. 반대 방향(권한 회수)도 구독해야 죽은 탭을 붙들고 있지 않는다.

```swift
import AppKit
import Combine
import DockMinimizerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    let permissions = PermissionsManager()
    private(set) var coordinator: Coordinator?
    private var menuBar: MenuBarController?
    private var permissionSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = Coordinator(settings: settings)
        self.coordinator = coordinator

        menuBar = MenuBarController(
            settings: settings,
            permissions: permissions,
            coordinator: coordinator
        )

        // 권한 상태 전환을 구독한다. startMonitoring 보다 먼저 구독해야
        // 초기 상태 변화를 놓치지 않는다.
        permissionSubscription = permissions.$isTrusted
            .removeDuplicates()
            .sink { [weak self] trusted in
                guard let self else { return }
                if trusted {
                    self.coordinator?.start()
                } else {
                    self.coordinator?.stop()
                    self.permissions.requestAccess()
                }
            }

        permissions.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionSubscription = nil
        coordinator?.stop()
        permissions.stopMonitoring()
    }
}
```

`Coordinator.start()`와 `stop()`은 `isRunning` 가드가 있으므로 중복 호출이 안전하다. `@Published`는 구독 즉시 현재 값을 내보내므로, 이미 권한이 있는 상태로 실행되면 곧바로 `start()`가 호출된다.

`MenuBarController`의 시그니처가 바뀌었으므로 Task 16까지는 빌드가 실패한다. 두 작업을 연속으로 진행한다.

- [ ] **Step 3: 커밋 (Task 16 완료 후)**

이 Task는 Task 16과 함께 커밋한다.

## Task 16: 설정 창

**Files:**
- Create: `Sources/DockMinimizer/SettingsWindow.swift`

- [ ] **Step 1: `Sources/DockMinimizer/SettingsWindow.swift` 작성**

```swift
import AppKit
import DockMinimizerCore
import SwiftUI

/// 설정 창의 상태를 SwiftUI에 노출하는 어댑터.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            // reloadFromSettings가 값을 밀어 넣을 때는 되쓰지 않는다.
            guard !isSyncing else { return }
            settings.isEnabled = isEnabled
            coordinator.settingsDidChange()
        }
    }
    @Published private(set) var exclusions: [String]

    let settings: Settings
    let permissions: PermissionsManager
    private let coordinator: Coordinator
    private var isSyncing = false

    init(settings: Settings, permissions: PermissionsManager, coordinator: Coordinator) {
        self.settings = settings
        self.permissions = permissions
        self.coordinator = coordinator
        self.isEnabled = settings.isEnabled
        self.exclusions = settings.userExcludedBundleIDs.sorted()
    }

    /// 메뉴바에서 활성화를 토글하면 이 모델은 모르므로, 창을 열 때마다 실제 설정을 다시 읽는다.
    /// `Settings`가 유일한 진실이고 이 모델은 그 사본이다.
    func reloadFromSettings() {
        isSyncing = true
        isEnabled = settings.isEnabled
        isSyncing = false
        exclusions = settings.userExcludedBundleIDs.sorted()
    }

    func addExclusionViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "제외에 추가"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            settings.addExclusion(bundleID)
        }
        reload()
    }

    func remove(_ bundleID: String) {
        settings.removeExclusion(bundleID)
        reload()
    }

    private func reload() {
        reloadFromSettings()
        coordinator.settingsDidChange()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var permissions: PermissionsManager
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Dock 클릭으로 최소화 활성화", isOn: $model.isEnabled)
                .font(.headline)

            Divider()

            permissionSection

            Divider()

            exclusionSection
        }
        .padding(20)
        .frame(width: 420, height: 400)
    }

    @ViewBuilder
    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("접근성 권한").font(.headline)
            if permissions.isTrusted {
                Label("권한이 부여되었습니다", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("권한이 없어 동작하지 않습니다", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("시스템 설정 열기") {
                    permissions.openSystemSettings()
                }
            }
        }
    }

    @ViewBuilder
    private var exclusionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("제외할 앱").font(.headline)
            Text("Finder는 항상 제외됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(model.exclusions, id: \.self, selection: $selection) { bundleID in
                Text(bundleID)
            }
            .frame(minHeight: 140)

            HStack {
                Button("추가...") { model.addExclusionViaPanel() }
                Button("제거") {
                    if let selection { model.remove(selection) }
                }
                .disabled(selection == nil)
            }
        }
    }
}

/// 설정 창을 소유하는 컨트롤러. 창을 닫아도 앱이 종료되지 않도록 참조를 유지한다.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel
    private let permissions: PermissionsManager

    init(model: SettingsModel, permissions: PermissionsManager) {
        self.model = model
        self.permissions = permissions
    }

    func show() {
        // 메뉴바에서 바뀐 값이 있을 수 있으므로 열 때마다 실제 설정을 다시 읽는다.
        model.reloadFromSettings()
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(model: model, permissions: permissions)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "DockMinimizer 설정"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // LSUIElement 앱은 기본적으로 창을 앞으로 못 가져오므로 명시적으로 활성화한다.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 2: 다음 Task와 함께 빌드**

`MenuBarController`가 아직 갱신되지 않았으므로 Task 17에서 함께 빌드한다.

## Task 17: 메뉴바 완성

**Files:**
- Modify: `Sources/DockMinimizer/MenuBarController.swift`

- [ ] **Step 1: `Sources/DockMinimizer/MenuBarController.swift` 전체 교체**

```swift
import AppKit
import DockMinimizerCore
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settings: Settings
    private let permissions: PermissionsManager
    private let coordinator: Coordinator
    private let settingsWindow: SettingsWindowController
    private let model: SettingsModel

    private let enabledItem = NSMenuItem(title: "활성화", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 시작", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(settings: Settings, permissions: PermissionsManager, coordinator: Coordinator) {
        self.settings = settings
        self.permissions = permissions
        self.coordinator = coordinator
        self.model = SettingsModel(
            settings: settings, permissions: permissions, coordinator: coordinator
        )
        self.settingsWindow = SettingsWindowController(model: model, permissions: permissions)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "dock.arrow.down.rectangle",
            accessibilityDescription: "DockMinimizer"
        )
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        enabledItem.target = self
        enabledItem.action = #selector(toggleEnabled)
        menu.addItem(enabledItem)

        loginItem.target = self
        loginItem.action = #selector(toggleLoginItem)
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "설정...", action: #selector(openSettings), keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    /// 메뉴가 열릴 때마다 실제 상태를 다시 읽어 체크마크를 맞춘다.
    func menuWillOpen(_ menu: NSMenu) {
        enabledItem.state = settings.isEnabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if DockIndex.isDockMagnificationEnabled {
            // 확대 중에는 DockIndex가 빈 스냅샷을 내보내 기능이 멈춘다. 그 이유를 알린다.
            permissionItem.title = "Dock 확대가 켜져 있어 일시 중지됨"
        } else if permissions.isTrusted {
            permissionItem.title = "접근성 권한: 정상"
        } else {
            permissionItem.title = "접근성 권한 없음 — 설정에서 허용 필요"
        }
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        coordinator.settingsDidChange()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인 항목 설정에 실패했습니다"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
```

- [ ] **Step 2: 빌드**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: 설치 후 확인**

Run: `./Scripts/install.sh`

메뉴바 아이콘을 클릭해 다음을 확인한다.
- `접근성 권한: 정상`이 표시된다
- `활성화`에 체크마크가 있다
- `활성화`를 끄면 Dock 클릭 최소화가 동작하지 않는다
- 다시 켜면 동작한다

- [ ] **Step 4: 설정 창 확인**

메뉴에서 `설정...`을 연다. 창이 앞으로 나오고, `추가...`로 앱을 하나 제외에 넣은 뒤 그 앱에서 Dock 클릭이 더 이상 최소화하지 않는지 확인한다. 그 후 제거한다.

- [ ] **Step 5: 메뉴와 설정 창의 동기화 확인**

설정 창을 열어 둔 채 메뉴바에서 `활성화`를 토글한다. 설정 창을 닫았다가 다시 연다.

Expected: 설정 창의 체크박스가 메뉴바에서 바꾼 값과 일치한다.

- [ ] **Step 6: 권한 부여 시점 동작 확인 — 문서화된 설치 경로**

시스템 설정 > 손쉬운 사용에서 DockMinimizer 권한을 **끈다**. Dock 클릭 최소화가 멈추는지 확인한다. 다시 **켠다**.

Expected: **앱을 재실행하지 않고도** Dock 클릭 최소화가 다시 동작한다. 재실행해야만 동작한다면 `AppDelegate`의 `permissionSubscription`이 연결되지 않은 것이다.

- [ ] **Step 7: 로그인 시 시작 확인**

메뉴에서 `로그인 시 시작`을 켠다.

Run: `sfltool dumpbtm 2>/dev/null | grep -A2 dockminimizer || echo "sfltool 사용 불가 — 시스템 설정 > 일반 > 로그인 항목에서 육안 확인"`
Expected: DockMinimizer가 로그인 항목에 등록되어 있다.

- [ ] **Step 8: 커밋**

```bash
git add -A
git commit -m "feat: 권한 관리, 설정 창, 메뉴바 완성"
```

---

# Phase 4 — 검증과 마무리

## Task 18: 엣지 케이스 검증

**Files:**
- Create: `docs/superpowers/specs/2026-07-30-verification.md`

- [ ] **Step 1: 검증 문서 생성**

`docs/superpowers/specs/2026-07-30-verification.md`에 아래 체크리스트를 복사하고, 각 항목을 실제로 수행하며 결과(통과 / 실패 + 증상)를 기록한다.

```markdown
# DockMinimizer 검증 기록

검증일:
빌드:

## Dock 설정
- [ ] Dock 확대 켜짐 — 올바른 아이콘이 매칭되는가
- [ ] Dock 위치 왼쪽
- [ ] Dock 위치 오른쪽
- [ ] Dock 자동 숨김 켜짐
- [ ] 멀티 디스플레이 — Dock이 있는 화면
- [ ] 멀티 디스플레이 — Dock이 없는 화면(오작동이 없어야 함)

## 클릭 대상
- [ ] 최근 사용 항목 영역 클릭 — 개입하지 않는다
- [ ] 스택/폴더 클릭 — 평소대로 열린다
- [ ] 휴지통 클릭 — 평소대로 열린다
- [ ] **"윈도우를 앱 아이콘으로 최소화" 끔 (기본값)** — 최소화가 Dock 폭을 바꿔 모든 아이콘이 밀린다. 최소화 직후 옆 아이콘을 클릭해 엉뚱한 앱이 최소화되지 않는지
- [ ] **"윈도우를 앱 아이콘으로 최소화" 켬** — 위 문제가 사라지는 설정. 둘 다 확인해야 버그가 숨지 않는다

## 앱 상태
- [ ] 풀스크린 앱 — 최소화되지 않고 기존 동작 유지
- [ ] 윈도우 0개인 메뉴바 전용 앱 — 개입하지 않는다
- [ ] 여러 스페이스에 윈도우를 가진 앱
- [ ] 일부 윈도우만 이미 최소화된 앱 — 나머지만 최소화된다
- [ ] Finder — 개입하지 않는다
- [ ] 여러 윈도우를 가진 앱 — 전부 최소화된다
- [ ] 빠른 연속 클릭 — 최소화/복원이 매번 번갈아 일어난다 (정착 구간)
- [ ] 기능을 끄거나 앱을 제외 목록에 넣은 뒤에도, 전부 최소화된 앱을 Dock의 최소화 윈도우 항목으로 복구할 수 있다

## 입력 변형
- [ ] 우클릭 — 컨텍스트 메뉴가 정상 표시된다
- [ ] ⌘클릭 — 개입하지 않는다
- [ ] 옵션클릭 — 개입하지 않는다
- [ ] 더블클릭 — 이상 동작이 없다
- [ ] Dock 아이콘 드래그 — 아이콘 재배열이 정상 동작한다

## 시스템 이벤트
- [ ] `killall Dock` 후 클릭 — 재인덱싱되어 계속 동작한다
- [ ] 접근성 권한을 껐다 켜기 — 메뉴바 상태가 반영되고, 재실행 없이 동작이 재개된다
- [ ] Dock 확대 켜기/끄기 — Phase 0에서 정한 Case A/Case B 방침대로 동작한다
- [ ] 디스플레이 해상도 변경 후 클릭
- [ ] `./Scripts/install.sh` 재실행 — 접근성 권한이 유지된다
- [ ] 30분 이상 실행 후에도 동작 유지 (탭이 죽지 않는다)
```

- [ ] **Step 2: 체크리스트 전수 수행**

각 항목을 실제로 수행한다. 실패한 항목은 증상을 기록하고 원인을 조사한다.

- [ ] **Step 3: 장시간 안정성 확인**

30분 이상 사용한 뒤 로그를 확인한다.

Run: `log show --predicate 'subsystem == "com.changhun.dockminimizer"' --last 30m --info --debug | grep -E '느립니다|비활성화'`
Expected: 출력이 비어 있다. `이벤트 탭이 비활성화됨`이 반복해 나오면 콜백에 AX 호출이 섞여 든 것이므로 `DockIndex`와 `AppStateCache` 사용부를 다시 점검한다.

- [ ] **Step 4: 실패 항목 수정**

발견된 문제는 근본 원인을 찾아 수정하고, 가능하면 `ClickRouter` 레벨의 회귀 테스트로 고정한 뒤 다시 검증한다.

- [ ] **Step 5: 커밋**

```bash
git add -A
git commit -m "test: 엣지 케이스 검증 기록"
```

## Task 19: README와 마무리

**Files:**
- Create: `README.md`

- [ ] **Step 1: `README.md` 작성**

```markdown
# DockMinimizer

활성 상태인 앱의 Dock 아이콘을 클릭하면 그 앱의 윈도우를 최소화하는 macOS 메뉴바 앱.
한 번 더 클릭하면 복원된다.

## 요구 사항

- macOS 14 이상
- Swift 6 툴체인 (Xcode 또는 Command Line Tools)

## 설치

```bash
./Scripts/make-cert.sh   # 최초 1회. 고정 코드서명 인증서를 만든다
./Scripts/install.sh     # 빌드 후 /Applications 에 설치하고 실행한다
```

설치 후 **시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용**에서
`/Applications/DockMinimizer.app`을 추가하고 켠다. 이 권한이 없으면 동작하지 않는다.

`make-cert.sh`로 만든 고정 인증서를 쓰기 때문에 재빌드해도 이 권한은 유지된다.
ad-hoc 서명(`codesign -s -`)을 쓰면 빌드마다 권한이 사라진다.

## 사용

메뉴바 아이콘에서 활성화 여부, 로그인 시 시작, 설정 창을 제어한다.
설정 창에서 특정 앱을 제외 목록에 넣을 수 있다. Finder는 항상 제외된다.

## 개발

```bash
swift build          # 빌드
swift test           # 순수 로직 테스트
swift run DockProbe  # Dock AX 트리 덤프 (디버깅용)
swift run DockProbe watch  # 클릭과 아이콘 매칭 실시간 관찰
```

로그 확인:

```bash
log show --predicate 'subsystem == "com.changhun.dockminimizer"' --last 10m --info --debug
```

## 구조

판정 로직 전체가 `DockMinimizerCore`의 순수 함수 `ClickRouter.decide`에 모여 있고
단위 테스트로 고정되어 있다. 나머지 모듈은 그 함수에 넣을 입력을 준비하고 결과를 실행한다.

가장 중요한 제약은 **이벤트 탭 콜백에서 AX API를 호출하지 않는 것**이다.
Dock AX 조회는 수십 밀리초가 걸리는 IPC이고, 콜백이 지연되면 macOS가 탭을 조용히 죽여
"한동안 잘 되다가 갑자기 멈추는" 증상이 나타난다. `DockIndex`와 `AppStateCache`가
모든 AX 조회를 백그라운드에서 미리 수행해 불변 스냅샷으로 캐싱하는 이유다.

두 번째로 중요한 것은 **복원도 이 앱이 직접 한다**는 점이다. Dock은 프론트모스트 앱의
윈도우가 전부 최소화된 상태에서 아이콘을 클릭해도 아무 일도 하지 않는다(Phase 0 실측).
윈도우를 최소화해도 앱은 프론트모스트로 남으므로, Dock의 기본 복원에 기대면 사용자가
앱을 되살릴 수 없게 된다. 그래서 `ClickRouter`는 프론트모스트 앱의 윈도우 상태에 따라
최소화·복원·무시의 3분기로 판정한다.

세 번째는 **최소화가 Dock 레이아웃을 바꾼다**는 점이다. 최소화된 윈도우가 Dock에 별도
아이콘으로 추가되면 가운데 정렬이 다시 계산되어 모든 아이콘의 x좌표가 밀린다. 이 변화는
어떤 시스템 알림으로도 통보되지 않으므로, 최소화·복원 직후 `DockIndex`를 직접 갱신한다.
그러지 않으면 다음 클릭이 이웃 앱을 최소화한다.

## 알려진 제약

- App Store 배포 불가. 샌드박스가 이벤트 탭 생성을 금지한다
- 접근성 권한이 필수다
```

- [ ] **Step 2: 전체 테스트 실행**

Run: `swift test`
Expected: PASS — 모든 테스트 통과

- [ ] **Step 3: 클린 빌드 확인**

Run: `rm -rf .build build && ./Scripts/install.sh`
Expected: `완료.` 그리고 접근성 권한이 유지된 채 정상 동작한다.

- [ ] **Step 4: 커밋**

```bash
git add -A
git commit -m "docs: README 추가"
```
