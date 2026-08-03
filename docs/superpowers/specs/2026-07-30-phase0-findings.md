# Phase 0 실측 결과

측정일: 2026-08-03
환경: macOS 26.5.2 (Tahoe), arm64, 디스플레이 1800×1169, Dock 하단·tilesize 43·확대 꺼짐
도구: `swift run DockProbe` / `swift run DockProbe experiment`

측정은 사람의 관찰이 아니라 합성 클릭 + AX 상태 읽기로 자동화했다. 판정이 애매해지지 않고 재현 가능하다.

## 요약

| # | 질문 | 답 | 영향 |
|---|---|---|---|
| 1 | AXList 개수와 순회 | **1개**. 모든 항목이 단일 리스트 | 재귀 수집 유지 (구조 변경 대비) |
| 2 | bundleID 획득 | **`AXURL` → `Bundle(url:)`** | 교차 조회 불필요 |
| 3 | 좌표 변환 | **불필요.** AX와 CGEvent가 같은 공간 | 그대로 사용 |
| 4 | Plan A / Plan B | ~~Plan A~~ → **Plan B**. 액티브 탭 | §4 정정 참조 |
| 5 | Dock 확대 | **Case B**. AX 프레임이 정적 | 확대 중 기능 일시 중지 |
| 6 | **Dock의 복원 동작** | **프론트모스트 앱은 복원하지 않는다** | **설계 변경 — 아래 참조** |
| 7 | **최소화 시 subrole 변화** | **AXStandardWindow → AXDialog** | **술어 변경 — 아래 참조** |

## 1. Dock AX 구조

`AXApplication(Dock)` → `AXList` **1개** → `AXDockItem` 34개.

subrole로 종류가 명확히 구분된다.

| subrole | 예 | `AXURL` | `AXIsApplicationRunning` |
|---|---|---|---|
| `AXApplicationDockItem` | Finder, Safari, 메모 | `.app` 번들 경로 | 0/1 |
| `AXSeparatorDockItem` | 구분선 | 없음 | 없음 |
| `AXFolderDockItem` | 다운로드 | **디렉터리 경로 (있음)** | 없음 |
| `AXMinimizedWindowDockItem` | `(1165) YouTube` | 없음 | 없음 |
| `AXTrashDockItem` | 휴지통 | 없음 | 없음 |

**폴더 항목도 `AXURL`을 가진다.** 따라서 "bundleID가 nil이면 앱이 아니다"라는 판정에만 의존하면 안 되고, **`subrole == "AXApplicationDockItem"`으로 먼저 걸러야 한다.**

`AXIsApplicationRunning`이 존재하므로 `NSWorkspace.runningApplications`와의 교차 조회가 필요 없다.

## 2. 좌표계

Dock AX 프레임: `(157, 1102, 1486, 57)`, 아이콘 `(159.75, 1102, 45, 57)`.
화면: `NSScreen.frame = (0, 0, 1800, 1169)`.

AX 위치는 **좌상단 원점**이고 `CGEvent.location`과 동일한 공간이다. 아이콘 중심으로 커서를 워프한 뒤 `CGEvent(source:).location`을 읽어 확인했다.

```
워프 목표    : (182.2499, 1130.5)
워프 후 커서 : (182.0, 1130.0)
오차         : dx=0.25 dy=0.5   ← 정수 반올림
```

**좌표 변환식 불필요.**

## 3. Dock 확대 — Case B

`magnification = true`, `largesize = 96`으로 설정한 뒤 측정.

```
대상 아이콘       : Gemini
커서 멀리 있을 때 : (834.7499, 1102, 45, 57)
커서 올렸을 때    : (834.7499, 1102, 45, 57)
```

**AX 프레임은 확대의 영향을 받지 않는다 (Case B).** 확대 시 아이콘이 시각적으로 커지고 이웃이 밀려나므로, 사용자가 클릭한 좌표가 정적 프레임과 어긋날 수 있다.

정적 프레임이 확대 중에도 여전히 올바른 히트테스트인지는 **측정하지 못했다.** `AXSelected`는 호버를 추적하지 않고(확대 OFF 기준선에서도 0/6), 합성 클릭 후 활성 앱을 보는 방식은 Dock 자체가 프론트모스트가 되어 버려 무효였다.

→ 계획에 미리 정해 둔 **Case B 분기를 채택한다: 확대가 켜져 있는 동안 기능을 일시 중지하고 메뉴바에 표시한다.** 보수적이지만 오작동이 없다. 확대 지원은 별도 실험이 필요한 후속 과제로 남긴다.

측정 후 원래 설정으로 복원했다 (`magnification` 미설정, `largesize=16`).

## 4. Dock의 기본 동작 — Plan A 확정

프론트모스트 앱의 Dock 아이콘을 합성 클릭하고 윈도우 상태 변화를 측정했다.

| 상태 | 프론트모스트 | 윈도우 | Dock 기본 동작 |
|---|---|---|---|
| 1 | 대상 앱 | 전부 보임 | **아무 것도 안 함** |
| 2 | 대상 앱 | 전부 최소화 | **아무 것도 안 함** |
| 3 | 대상 앱 | 일부만 최소화 | **아무 것도 안 함** |
| 4 | 다른 앱 | 최소화 | 활성화 + 복원 |

우리가 개입하는 상태(1·2·3)에서 Dock은 **스스로는** 아무 일도 하지 않는다.

### ★ 정정 (구현 검증 중 발견): 이 표만으로 Plan A를 결론지은 것은 틀렸다

위 측정은 "Dock이 혼자서 무엇을 바꾸는가"를 본 것이고, **"우리가 바꾼 것을 Dock이 되돌리는가"는 보지 않았다.** 둘은 다르다.

격리 실험으로 확인했다.

```
[대조군] 클릭 없이 최소화만
  setMinimized 결과=true
  +100ms ~ +1300ms: minimized=true   ← 유지된다

[실험군] Dock 클릭 + 같은 시점에 최소화 (앱과 동일한 타이밍)
  setMinimized 결과=true
  +100ms ~ +1900ms: minimized=false  ← Dock이 되돌린다
```

`AXUIElementSetAttributeValue`는 `.success`를 반환하고 앱 로그도 `최소화 윈도우=1개`를 남기지만, 리슨 전용 탭에서는 클릭이 Dock에도 전달되고 Dock이 100ms 안에 윈도우를 원상복구한다. **증상은 "아무 일도 일어나지 않음"이라 원인이 전혀 드러나지 않는다.**

**따라서 Plan B가 필요하다: `kCGEventTapOptionDefault` 액티브 탭으로, 개입하는 클릭의 mouseDown과 짝이 되는 mouseUp을 삼킨다.** 삼킨 뒤 재검증한 결과 최소화 → 복원 → 최소화 → 복원 토글이 정확히 동작했고, 프론트모스트가 아닌 앱의 아이콘 클릭은 평소대로 활성화되었다(삼키지 않으므로).

교훈: Dock의 기본 동작을 측정할 때는 **우리 동작과 겹친 상태**에서 측정해야 한다.

### 측정 도구에서 걸러낸 함정

`CGEvent.post(tap:)`를 `.cgSessionEventTap`으로 보내면 **Dock에 전달되지 않는다.** 처음 측정에서 "아무 일도 일어나지 않는다"는 결과가 나온 원인이었다. `.cghidEventTap`으로 보내야 실제 클릭과 동일하게 동작한다. 상태 4에서 복원이 관찰된 것이 이 사실의 증거다.

## 4.5 Dock 재정렬 — 실측으로 확인

메모 윈도우를 최소화하자 Safari 아이콘의 x좌표가 **22.5pt** 이동했다. 최소화된 윈도우가 Dock에 별도 아이콘으로 추가되고 가운데 정렬이 다시 계산되기 때문이다. 아이콘 폭 45pt의 정확히 절반이다.

`DockIndex.refreshAfterWindowChange()`로 대응했고, 최소화 직후 이웃 아이콘을 클릭하는 검증이 통과했다.

## 5. ★ Dock은 프론트모스트 앱을 복원하지 않는다 — 설계 변경

가장 중요한 발견이다.

```
0. 활성화 직후          frontmost=메모  isActive=true  windows=[vis]
1. 우리가 최소화한 뒤     frontmost=메모  isActive=true  windows=[min]
2. Dock 아이콘 1차 클릭   frontmost=메모  isActive=true  windows=[min]
3. Dock 아이콘 2차 클릭   frontmost=메모  isActive=true  windows=[min]
```

앱은 윈도우가 하나도 없어도 프론트모스트로 남고, 그 상태에서 Dock 아이콘을 아무리 클릭해도 복원되지 않는다. **우리 앱이 만들어 내는 상태가 정확히 이 상태다.**

설계 문서 §6의 이중 가드는 "우리는 개입하지 않고 Dock 기본 복원에 맡긴다(`.letThrough`)"를 전제했으나, **그 기본 복원이 존재하지 않는다.** 그대로 구현하면 사용자가 앱을 되살릴 수 없다 — 설계가 막으려던 바로 그 사고다.

**변경:** `Decision`에 `.restore(pid:)`를 추가하고 **우리 앱이 직접 복원**한다.

```
프론트모스트 아님              → .ignore          (Dock이 활성화 + 복원. 상태 4)
프론트모스트 + 보이는 윈도우 있음  → .minimize(pid)
프론트모스트 + 보이는 윈도우 없음  → .restore(pid)   ← 신규
```

주 판별자가 `hasVisibleWindows`로 단순해진다. `minimizedByUs`는 최소화 직후 캐시가 갱신되기 전(최대 0.5초)의 즉시 신호로만 유지한다.

## 6. ★ 최소화하면 subrole이 바뀐다 — 술어 변경

```
최소화 전: subrole=AXStandardWindow minimized=false
최소화 후: subrole=AXDialog         minimized=true
```

동일한 윈도우인데 최소화하면 subrole이 `AXStandardWindow`에서 `AXDialog`로 바뀐다. 계획의 `Minimizer`와 `hasVisibleWindows`는 `subrole == kAXStandardWindowSubrole`로 걸렀는데, 그러면 **최소화된 윈도우가 목록에서 사라진 것처럼 보인다.** 복원 경로에서 대상 윈도우를 찾지 못하게 된다.

**변경 — 윈도우 술어:**

```swift
// AXMinimized 속성을 가진 윈도우를 대상으로 하고, 최소화 대상이 아닌 subrole만 제외한다.
let excludedSubroles: Set<String> = ["AXSheet", "AXSystemDialog", "AXSystemFloatingWindow"]
```

## 7. 남은 제약

- Dock 확대 지원은 미해결. Case B 분기(일시 중지)로 우회한다
- 멀티 디스플레이는 이 환경(단일 디스플레이)에서 측정하지 못했다. Phase 4 검증 항목으로 남는다
- Dock 위치 좌/우, 자동 숨김도 Phase 4에서 확인한다
