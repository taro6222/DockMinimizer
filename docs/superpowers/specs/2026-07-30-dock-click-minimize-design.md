# DockMinimizer 설계 문서

작성일: 2026-07-30
상태: 승인됨 (구현 계획 작성 대기)

## 1. 목적

실행 중인 앱이 프론트모스트 상태일 때 Dock에서 그 앱의 아이콘을 클릭하면, 해당 앱의 윈도우를 최소화한다. macOS 기본 동작에서는 이 클릭이 사실상 아무 일도 하지 않는다.

성공 기준:

- 프론트모스트 앱의 Dock 아이콘 클릭 → 해당 앱의 모든 표준 윈도우가 최소화된다
- 한 번 더 클릭 → 복원된다 (앱이 되살아나지 않는 상태에 갇히지 않는다)
- 프론트모스트가 아닌 앱의 아이콘 클릭 → 기존 동작(활성화) 그대로
- Dock의 다른 상호작용(우클릭 메뉴, 드래그, 스택, 휴지통)을 깨뜨리지 않는다
- 장시간 실행해도 동작이 멈추지 않는다

## 2. 확인된 전제

- 대상 환경: macOS 26.5.2 (Tahoe), arm64, Xcode 26.6, Swift 6.3.3
- 서드파티 앱이 다른 앱의 Dock 아이콘 클릭을 알아내는 공개 API는 존재하지 않는다. `NSWorkspace` 활성화 알림은 활성화의 원인이 Dock 클릭인지 알려주지 않는다. SIP 우회 및 코드 인젝션은 범위 밖이다. 따라서 `CGEventTap`으로 마우스 클릭을 관찰하고 Dock 프로세스의 접근성(AX) 트리에서 아이콘 프레임을 조회해 어느 아이콘이 눌렸는지 역산하는 방식이 유일한 경로다.
- 접근성 권한이 없으면 Dock의 AX 트리는 빈 값을 반환한다 (실측 확인: `AXIsProcessTrusted: false`인 상태에서 루트 엘리먼트의 role/children이 모두 비어 있음). 접근성 권한 하나로 이벤트 탭 생성과 AX 조회가 모두 커버된다.
- App Store 배포는 불가능하다. 샌드박스가 이벤트 탭 생성을 금지한다.
- Phase 0 실측으로 다음이 확정되었다 (`2026-07-30-phase0-findings.md`): AX 좌표와 `CGEvent.location`은 같은 공간이라 변환이 불필요하고, Dock 항목은 `subrole == "AXApplicationDockItem"`으로 걸러야 하며(폴더 항목도 `AXURL`을 가진다), 윈도우는 최소화되면 subrole이 `AXStandardWindow`에서 `AXDialog`로 바뀌므로 subrole로 필터하면 안 된다.

## 3. 결정 사항

| 항목 | 결정 | 근거 |
|---|---|---|
| 최소화 방식 | Minimize (`kAXMinimized = true`) | 요구사항의 "최소화"에 문자적으로 일치. 지니 애니메이션 유지 |
| 적용 범위 | 모든 앱 + 사용자 제외 목록 | 실사용에서 가장 자연스럽고, 문제 앱은 개별 회피 가능 |
| UI 범위 | 메뉴바 아이콘 + 설정 창 + 로그인 시 시작 | 실제로 상시 사용 가능한 완성품 |
| 서명·배포 | 고정 self-signed 인증서 + `/Applications` 로컬 설치 | TCC 권한이 코드 서명에 묶이므로 재빌드 후에도 권한 유지 |
| 앱 형태 | `LSUIElement = true` 메뉴바 에이전트 | 자기 자신이 Dock 아이콘을 갖지 않아 자기를 최소화하는 사고를 구조적으로 차단 |

## 4. 아키텍처

### 4.1 모듈

| 모듈 | 책임 | 의존 |
|---|---|---|
| `PermissionsManager` | 접근성 권한 확인·요청, 시스템 설정 딥링크, 사후 회수 감지 | AX API |
| `DockIndex` | Dock AX 트리 → `[DockItem]` 불변 스냅샷 캐시 및 갱신 | AX API, NSWorkspace |
| `AppStateCache` | frontmost pid/bundleID, 보이는/최소화된 윈도우 유무, 정착 구간 | NSWorkspace 알림, 타이머 |
| `ClickRouter` | **순수 로직.** (클릭 좌표, 스냅샷, 앱 상태, 설정) → `Decision` | 없음 |
| `EventTapController` | 이벤트 탭 생성·수명 관리·비활성화 복구 | CGEvent API |
| `WindowController` | 대상 앱 윈도우의 `kAXMinimized` 설정·해제 | AX API |
| `Settings` | 활성화 여부, 제외 목록, 로그인 시작 | UserDefaults, SMAppService |
| `MenuBarController` | 메뉴바 아이콘과 메뉴 | AppKit |
| `SettingsWindow` | 설정 UI | SwiftUI |

### 4.2 핵심 데이터 타입

```swift
struct DockItem {
    let frame: CGRect        // 전역 디스플레이 좌표 (좌상단 원점, CGEvent.location과 동일)
    let bundleID: String?
    let title: String?
}

struct DockSnapshot {
    let items: [DockItem]
}

struct AppState {
    let pid: pid_t
    let bundleID: String
    let hasVisibleWindows: Bool     // 최소화되지 않은 대상 윈도우 ≥ 1
    let hasMinimizedWindows: Bool   // 최소화된 대상 윈도우 ≥ 1
}

enum Decision: Equatable {
    case ignore                 // 우리 관심사가 아님
    case minimize(pid: pid_t)
    case restore(pid: pid_t)    // Dock이 복원하지 않으므로 우리가 한다
}
```

### 4.3 데이터 흐름

```
[마우스 클릭]
      │
      ▼
EventTapController 콜백  ── AX 호출 절대 금지, 마이크로초 단위로 반환 ──┐
      │                                                              │
      │ 읽기 전용: DockSnapshot(원자적 스냅샷) + AppStateCache        │
      ▼                                                              │
ClickRouter.decide(...) → Decision                                   │
      │                                                              │
      ├─ .ignore → 즉시 반환                                        │
      └─ .minimize / .restore → 백그라운드 큐로 async dispatch ───────┘
                                │
                                ▼
              WindowController.minimize / .restore (AX)
                                │
                                ├─→ AppStateCache 즉시 갱신 + 800ms 정착 구간
                                │
                                └─→ DockIndex.refresh() 즉시 + 700ms 후 한 번 더
                                     (최소화가 Dock 폭을 바꿔 모든 아이콘이 밀리므로)

[백그라운드 갱신 경로]
NSWorkspace 알림(앱 실행/종료/숨김)   ┐
화면 구성 변경 알림                    ├→ 시리얼 큐에서 AX 조회
우리 동작 직후 / 700ms 후              │   → 새 DockSnapshot 생성
1초 안전망 타이머                      ┘   → 원자적으로 교체
```

## 5. 최우선 제약: 이벤트 탭 콜백에서 AX 호출 금지

이 프로젝트에서 가장 흔한 실패 모드다.

액티브 이벤트 탭에는 타임아웃이 있다. Dock의 AX 트리 조회는 크로스 프로세스 IPC로 수십 밀리초가 걸릴 수 있다. 콜백이 예산을 초과하면 macOS가 `kCGEventTapDisabledByTimeout`을 발생시키고 탭을 조용히 비활성화한다. 증상은 "잠깐 잘 되다가 갑자기 아무 반응이 없음"이며, 원인 추적이 매우 어렵다.

대응:

1. 콜백은 **캐시된 불변 스냅샷 읽기 + 사각형 히트테스트 + pid 정수 비교**만 수행한다. 락 없이 스냅샷 참조를 원자적으로 교체하는 방식을 쓴다.
2. `NSWorkspace.frontmostApplication`도 IPC일 수 있으므로 콜백에서 호출하지 않는다. `didActivateApplicationNotification`으로 미리 캐싱한 값을 읽는다.
3. 윈도우 상태 판정(보이는 윈도우 / 최소화된 윈도우 유무)도 AX 호출이므로 콜백에서 하지 않는다. `AppStateCache`가 미리 계산해 둔다.
4. `kCGEventTapDisabledByTimeout`과 `kCGEventTapDisabledByUserInput`을 명시적으로 처리해 `CGEventTapEnable(tap, true)`로 재활성화하고 경고 로그를 남긴다.
5. 콜백 실행 시간을 계측해 임계값 초과 시 진단 로그를 남긴다.

## 6. 복원 경로 — 3분기 판정 (Phase 0 실측으로 개정)

Hide(`NSRunningApplication.hide()`)와 달리 `kAXMinimized = true`는 앱을 프론트모스트로 남긴다. 당초 설계는 "우리는 개입하지 않고 Dock의 기본 복원에 맡긴다(`.letThrough`)"로 이 문제를 해결하려 했다.

**Phase 0 실측 결과 그 기본 복원은 존재하지 않는다.** 프론트모스트 앱의 윈도우가 전부 최소화된 상태에서 Dock 아이콘을 몇 번 클릭해도 아무 일도 일어나지 않는다. 우리가 만들어 내는 상태가 정확히 그 상태이므로, 원안대로 구현하면 사용자가 앱을 되살릴 수 없다.

**따라서 복원도 우리가 직접 수행한다.** 판정은 프론트모스트 앱의 윈도우 상태에 따른 3분기가 된다.

| 조건 | 판정 | 근거 |
|---|---|---|
| 프론트모스트가 아님 | `.ignore` | Dock이 활성화 + 복원을 알아서 한다 (실측 상태 4) |
| 프론트모스트 + 보이는 윈도우 ≥ 1 | `.minimize(pid)` | |
| 프론트모스트 + 보이는 윈도우 0, 최소화된 윈도우 ≥ 1 | `.restore(pid)` | Dock이 복원하지 않으므로 우리가 한다 |
| 프론트모스트 + 윈도우 없음 | `.ignore` | 메뉴바 전용 앱. 복원할 것이 없다 |

마지막 분기가 필요한 이유: `hasVisibleWindows == false`는 "전부 최소화됨"과 "윈도우가 아예 없음"을 구분하지 못한다. `hasMinimizedWindows`를 함께 두어 판정을 완전하게 만든다.

### 캐시 정착 구간

`AppStateCache`는 0.5초 주기로 AX를 다시 읽는다. 우리가 최소화/복원한 직후에는 AX가 아직 이전 상태를 보고할 수 있고, 그러면 타이머가 방금 갱신한 캐시를 되돌려 다음 클릭이 같은 방향으로 다시 동작한다.

**대응:** 동작 직후 캐시를 즉시 갱신하고, 그 뒤 800ms 동안은 타이머의 덮어쓰기를 막는다(정착 구간). 최소화와 복원 양쪽에 대칭으로 적용한다.

### 최소화가 Dock 레이아웃을 바꾼다

"윈도우를 앱 아이콘으로 최소화"가 꺼져 있으면(기본값) 최소화된 윈도우가 Dock에 **별도 아이콘으로 추가된다.** Dock은 가운데 정렬이므로 폭이 넓어지면 전체가 재정렬되어 **모든 앱 아이콘의 x좌표가 약 22pt(아이콘 폭의 절반) 밀린다.**

`DockIndex`의 갱신 트리거(앱 실행/종료/숨김/화면 변경/1초 타이머) 중 어느 것도 윈도우 최소화로는 발화하지 않는다. 그래서 최대 1초간 캐시가 어긋나고, 그 사이의 클릭이 **이웃 앱을 최소화한다.**

**대응:** 최소화/복원을 수행한 직후와 지니 애니메이션이 끝난 뒤(약 700ms) 각각 `DockIndex.refresh()`를 호출한다.

## 7. 클릭 삼킴 필요 — Plan B (구현 검증으로 확정)

Phase 0의 1차 측정에서는 우리가 개입하는 세 상태 모두에서 Dock의 기본 동작이 "아무 것도 하지 않음"으로 나왔고, 그래서 리슨 전용 탭(Plan A)으로 충분하다고 판단했다.

**그 판단은 틀렸다.** 그 측정은 "Dock이 혼자서 무엇을 바꾸는가"만 보았고 "우리가 바꾼 것을 Dock이 되돌리는가"는 보지 않았다. 격리 실험 결과, 클릭 없이 최소화하면 상태가 유지되지만 Dock 클릭과 같은 시점에 최소화하면 **100ms 안에 원상복구된다.**

`AXUIElementSetAttributeValue`가 `.success`를 반환하고 로그도 정상이라 증상은 그저 "아무 일도 일어나지 않음"으로 보인다. 원인이 전혀 드러나지 않는 종류의 버그다.

**결론: `kCGEventTapOptionDefault` 액티브 탭으로 개입하는 클릭을 삼킨다.**

- `.ignore`가 아닌 판정이 나오면 mouseDown을 삼키고(`return nil`), 짝이 되는 mouseUp도 삼킨다. mouseDown만 삼키면 Dock이 이상 상태에 빠진다
- `.ignore`면 그대로 통과시킨다. 프론트모스트가 아닌 앱 클릭, 우클릭, 제외 앱, Dock 바깥 클릭은 전부 평소대로 동작한다 (검증 통과)

액티브 탭은 타임아웃으로 죽을 위험이 있으므로 §5의 제약이 더욱 중요해진다. 콜백은 캐시 읽기와 기하 비교만 수행하고, `kCGEventTapDisabledByTimeout`을 잡아 재활성화한다.

## 8. Phase 0 스파이크 (게이트)

접근성 권한 부여가 필요하며, 여기서 나온 실측값이 이후 모든 구현의 근거가 된다. macOS 26 Tahoe에서 Dock이 개편되었으므로 과거 지식에 의존하지 않고 직접 확인한다.

검증 항목:

1. **Dock AX 트리 구조** — `AXList`가 몇 개인지 (과거에는 앱 / 최근 항목 / 휴지통이 별도 리스트였고, 전부 순회해야 한다). dock item이 실행 상태 속성을 노출하는지 아니면 `NSWorkspace.runningApplications`와 교차 조회해야 하는지. `AXURL`로 번들 경로를 얻을 수 있는지.
2. **좌표계 일치** — AX `kAXPositionAttribute`(좌상단 원점)와 `CGEvent.location`(좌상단 원점)이 실제로 동일한 좌표 공간인지.
3. **Dock 확대(magnification)** — 확대가 켜지면 아이콘 프레임이 마우스 위치에 따라 실시간으로 변한다. AX 프레임이 확대 반영값인지 확인한다. **캐시 전략이 무너질 수 있는 유일한 지점이므로 반드시 확인한다.** 확대 반영값이라면 캐시가 틀리게 되며, 이 경우 대안은 (a) 확대 미고려 정적 레이아웃 기준 히트테스트, (b) 확대 켜짐 상태 미지원 안내 중 하나다. Phase 0 결과를 보고 선택한다.
4. **Plan A / Plan B 판정** — 활성 앱 아이콘 클릭의 기본 동작 확인.
5. **Dock 배치 변형** — Dock 위치(하단/좌/우), 자동 숨김, 멀티 디스플레이 환경에서의 좌표.

주의: 프로브가 빈 트리를 반환하면 그것은 AX 계층이 없어서가 아니라 프로브를 실행한 프로세스에 접근성 권한이 없어서일 가능성이 높다. 권한 부여를 먼저 확인한다.

## 9. 구현 단계

**Phase 1 — 스캐폴딩과 서명 파이프라인 (코드보다 먼저)**

TCC 권한은 코드 서명과 번들 ID에 묶인다. 서명이 바뀌면 권한이 사라지고, "클릭을 안 먹는다"는 유령 버그를 쫓게 된다. 그래서 첫 로직보다 서명 파이프라인을 먼저 세운다.

- SPM 실행 타깃과 `.app` 번들 조립 스크립트
- `Info.plist`: `LSUIElement = true`, 고정 번들 ID `com.changhun.dockminimizer`
- 키체인에 self-signed 코드서명 인증서 1개 생성, 매 빌드 동일 인증서로 서명
- `/Applications/DockMinimizer.app` 고정 경로 설치 스크립트
- 산출물: 메뉴바 아이콘만 뜨는 껍데기 + 접근성 권한 1회 부여 완료

**Phase 2 — 핵심 로직 (테스트 우선)**

- `ClickRouter` 단위 테스트 작성 후 구현 (3분기 판정)
- `DockIndex` 캐시와 갱신 트리거 (동작 직후 갱신 포함)
- `EventTapController` (액티브 탭, 클릭 삼킴) 및 비활성화 복구
- `AppStateCache` — 윈도우 상태와 정착 구간
- `WindowController` — 최소화와 복원

**Phase 3 — 설정과 편의 기능**

- 제외 목록. Finder(`com.apple.finder`), 시스템 설정, 자기 자신은 기본 고정 제외
- `NSOpenPanel`로 제외 앱 추가
- 설정 창: 동작 활성 토글, 제외 목록, 권한 상태 표시와 시스템 설정 열기 버튼
- `SMAppService.mainApp`로 로그인 시 시작
- 메뉴바 활성/비활성 토글

**Phase 4 — 검증**

§11 엣지 케이스 체크리스트를 전수 확인한다.

## 10. 테스트 전략

**자동 테스트** — `ClickRouter`는 AX와 CGEvent에 의존하지 않는 순수 로직이므로 실제 판정 로직 전체를 단위 테스트로 검증한다.

- 히트테스트 기하 계산 (경계값, 아이콘 사이 간격, Dock 바깥 좌표)
- 제외 목록 판정
- `minimizedByUs` 상태머신 (최소화 → 복원 → 재최소화 순환, 외부 복원으로 인한 상태 정리)
- 이중 가드의 각 분기

AX와 CGEvent 경계는 프로토콜로 추상화해 fake를 주입한다.

**수동 검증** — 실제 Dock 동작은 자동화가 불가능하므로 Phase 4 체크리스트로 커버한다. `CGEvent` 합성 클릭으로 일부 보조 자동화를 시도하되, 합성 이벤트가 이벤트 탭에 잡히는지 여부에 따라 적용 범위가 달라지므로 주 검증 수단으로 삼지 않는다.

## 11. 엣지 케이스 체크리스트

Dock 설정:

- [ ] Dock 확대(magnification) 켜짐
- [ ] Dock 위치 왼쪽 / 오른쪽
- [ ] Dock 자동 숨김 켜짐
- [ ] 멀티 디스플레이 (Dock이 있는 화면 / 없는 화면)

클릭 대상:

- [ ] Dock의 최근 사용 항목 영역
- [ ] 스택 및 폴더
- [ ] 휴지통
- [ ] **"윈도우를 앱 아이콘으로 최소화" 끔 (기본값)** — 최소화가 Dock 폭을 바꿔 모든 아이콘이 밀린다. 연속 클릭 시 이웃 앱이 최소화되지 않는지
- [ ] **"윈도우를 앱 아이콘으로 최소화" 켬** — 위 문제가 사라지는 설정. 둘 다 확인해야 함

앱 상태:

- [ ] 풀스크린 앱 (`kAXMinimizable`이 false → 반드시 통과시킬 것)
- [ ] 윈도우가 0개인 메뉴바 전용 앱
- [ ] 여러 스페이스에 걸쳐 윈도우를 가진 앱
- [ ] 이미 일부 윈도우만 최소화된 앱
- [ ] Finder (기본 제외)

입력 변형:

- [ ] 우클릭 (개입 안 함)
- [ ] ⌘클릭 / 옵션클릭 / 컨트롤클릭 (개입 안 함)
- [ ] 더블클릭
- [ ] Dock 아이콘 드래그 시작

시스템 이벤트:

- [ ] `killall Dock` 후 pid 변경 → 재인덱싱
- [ ] 이벤트 탭 강제 비활성화 → 자동 복구
- [ ] 접근성 권한 사후 회수 → 감지 및 안내
- [ ] 기능을 끄거나 앱을 제외한 뒤에도, 전부 최소화된 앱을 Dock의 최소화 윈도우 항목으로 복구할 수 있는지
- [ ] 화면 해상도 / 디스플레이 배치 변경
- [ ] 장시간 실행 (수 시간) 후에도 동작 유지

## 12. 대안과 폐기 사유

- **Hide 방식 (`NSRunningApplication.hide()`)** — 앱이 프론트모스트에서 빠지므로 Dock의 기본 활성화가 곧 복원이 되고, §6의 복원 문제가 발생하지 않는다. 요구사항의 "최소화"라는 표현에 문자적으로 맞지 않아 채택하지 않았다. `.restore` 분기로 해결했으므로 전환 필요성은 사라졌으나, 최소화 방식이 특정 앱에서 문제를 일으키면 여전히 가장 단순한 대안이다.
- **`NSWorkspace` 활성화 알림만 사용** — 활성화의 원인이 Dock 클릭인지 알 수 없어 키보드 전환(⌘Tab) 등과 구분되지 않는다.
- **코드 인젝션 / SIP 우회** — 범위 밖.
- **App Store 배포** — 샌드박스가 이벤트 탭을 금지하므로 불가능.

## 13. 열린 항목

- **Dock 확대 지원.** AX 프레임이 확대에 영향받지 않음(Case B)은 확정했으나, 확대 중에도 정적 프레임 히트테스트가 올바른지는 측정하지 못했다. 보수적으로 확대가 켜진 동안 기능을 일시 중지한다. 지원하려면 별도 실험이 필요하다
- **멀티 디스플레이.** 단일 디스플레이 환경에서 측정해 확인하지 못했다. Phase 4 검증 항목
- **Dock 위치 좌/우, 자동 숨김.** Phase 4 검증 항목

실측 결과 전체는 `2026-07-30-phase0-findings.md`에 있다.
