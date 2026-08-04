# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트

DockMinimizer — 활성 상태인 앱의 Dock 아이콘을 클릭하면 그 앱의 윈도우를 최소화하는 macOS 메뉴바 앱.
Swift 6 / SwiftPM, 외부 의존성 없음, `LSUIElement` 에이전트. GPL-3.0-or-later.

문서는 한국어로 쓰여 있고 커밋 메시지도 한국어다.

## 명령

```bash
swift build
swift test                              # 24개
swift test --filter <함수명>             # 단일 테스트. 예: --filter minimizeRestoreMinimizeCycle
                                        # --filter는 함수명에 대한 정규식이다 (표시 이름 아님)

./Scripts/make-cert.sh                  # 최초 1회. 고정 코드서명 인증서
./Scripts/install.sh                    # 빌드 → /Applications 설치 → 실행
./Scripts/make-dmg.sh                   # 배포용 DMG

swift run DockProbe                     # Dock AX 트리 덤프
swift run DockProbe verify              # 설치된 앱 동작 검증 11개
swift run DockProbe race                # 리슨 전용 탭 회귀 테스트 (앱을 끄고 실행)
swift run DockProbe experiment          # 좌표계·확대·Dock 기본 동작 실측

log show --predicate 'subsystem == "com.changhun.dockminimizer"' --last 10m --info --debug
```

`verify`와 `race`는 실제로 설치된 `/Applications/DockMinimizer.app`을 대상으로 동작하며 접근성 권한이 필요하다.
`swift test`는 순수 로직만 다루므로 권한 없이 돌아간다.

## 아키텍처

타깃 3개.

- **`DockMinimizerCore`** — 순수 로직. AX도 CGEvent도 건드리지 않아 전 분기가 단위 테스트로 고정된다.
  앱의 모든 판정이 `ClickRouter.decide` 하나에 모여 있다.
- **`DockMinimizer`** — 앱. `ClickRouter`에 넣을 입력을 준비하고 결과를 실행하는 것이 전부다.
- **`DockProbe`** — 스파이크 겸 검증 도구. 플랫폼 동작 측정과 설치된 앱의 회귀 검증에 쓴다.

```
[클릭] → EventTapController 콜백 (AX 호출 금지, µs 단위 반환)
           읽기: DockIndex.snapshot + AppStateCache.frontmost + 설정 스냅샷
              ↓
         ClickRouter.decide → .ignore / .minimize(pid) / .restore(pid)
              ↓ (.ignore가 아니면 클릭을 삼키고 백그라운드 큐로 비동기 디스패치)
         WindowController.minimize / .restore
              ├→ AppStateCache 즉시 갱신 + 800ms 정착 구간
              └→ DockIndex.refreshAfterWindowChange()
```

## 이 코드의 형태를 결정한 플랫폼 제약

**여섯 가지 모두 실측으로 확인한 것이고, 배경을 모르면 버그나 과잉 설계로 보인다. 고치기 전에
`docs/superpowers/specs/2026-07-30-phase0-findings.md`를 읽을 것.** 각 항목은 어겼을 때의 증상을 함께 적었다.

1. **이벤트 탭 콜백에서 AX API를 호출하지 않는다.** Dock AX 조회는 수십 ms가 걸리는 IPC다. 콜백이
   예산을 넘기면 macOS가 `kCGEventTapDisabledByTimeout`으로 탭을 조용히 죽인다.
   → 증상: "한동안 잘 되다가 갑자기 멈춤", 오류 없음. `DockIndex`·`AppStateCache`가 존재하는 이유가 이것이다.

2. **개입하는 클릭은 삼켜야 한다.** `.defaultTap` 액티브 탭으로 `.ignore`가 아닌 판정의 mouseDown과
   짝이 되는 mouseUp을 삼킨다. 리슨 전용으로 바꾸면 클릭이 Dock에도 가고, 우리가 최소화한 직후
   Dock이 100ms 안에 되돌린다.
   → 증상: `AXUIElementSetAttributeValue`가 `.success`를 반환하고 로그도 정상인데 화면은 그대로.
   대가로 프론트모스트 앱 아이콘은 드래그 재배열이 불가능하다 — 양립할 수 없다.

3. **복원도 이 앱이 직접 한다.** 윈도우를 전부 최소화해도 앱은 프론트모스트로 남는데, 그 상태에서
   Dock 아이콘을 눌러도 macOS는 복원하지 않는다. `hasVisibleWindows`와 `hasMinimizedWindows` 두
   플래그로 최소화·복원·무시 3분기를 판정한다. 플래그가 둘인 이유는 "전부 최소화됨"과 "윈도우가
   아예 없음"(메뉴바 전용 앱)을 구분해야 하기 때문이다.

4. **최소화하면 Dock 폭이 바뀐다.** 최소화된 윈도우가 Dock에 아이콘으로 추가되고 가운데 정렬이
   다시 계산되어 **모든 아이콘의 x좌표가 22.5pt 밀린다.** 어떤 시스템 알림으로도 통보되지 않는다.
   → 증상: 최소화 직후의 클릭이 이웃 앱을 건드린다. `refreshAfterWindowChange()`가 이를 흡수한다.

5. **윈도우를 최소화하면 subrole이 `AXStandardWindow`에서 `AXDialog`로 바뀐다.**
   `WindowController`의 술어를 subrole 기준으로 바꾸면 안 된다. `AXMinimized` 속성 보유를 기준으로
   삼고 시트류만 제외한다.
   → 증상: 최소화된 윈도우를 찾지 못해 복원이 동작하지 않는다.

6. **Dock 항목은 `subrole == "AXApplicationDockItem"`으로 걸러야 한다.** 폴더 항목도 `AXURL`을 가지므로
   "bundleID가 nil이면 앱이 아니다"에만 의존하면 폴더가 통과한다.

`AppStateCache`의 800ms 정착 구간도 같은 성격이다. 최소화·복원 직후에는 AX가 아직 이전 상태를
보고할 수 있어, 0.5초 타이머가 방금 갱신한 캐시를 되돌리면 토글이 한쪽으로 죽는다.

## 검증

Dock이나 이벤트 탭 관련 코드를 고쳤다면 `verify`와 `race`를 **모두** 다시 돌린다.
`race`는 위 2번이 여전히 유효한지 확인하는 회귀 테스트다 — 대조군(클릭 없이 최소화)은 유지되고
실험군(Dock 클릭과 동시 최소화)은 되돌려져야 한다. 실험군이 유지되면 macOS 동작이 바뀐 것이므로
리슨 전용 탭으로 되돌릴 수 있는지 재검토한다.

**합성 클릭은 반드시 `.cghidEventTap`으로 post한다.** `.cgSessionEventTap`으로 보낸 클릭은 Dock에
전달되지 않아 모든 관찰이 "아무 일도 일어나지 않음"으로 나오고 잘못된 결론에 이른다.

메뉴바·설정 창 같은 UI도 접근성 API로 검증할 수 있다. `LSUIElement` 앱이라 `AXMenuBar`는 nil이고
상태 항목은 `AXExtrasMenuBar` 아래에 있으며, 메뉴 항목에 `AXPress`를 보내고
`AXMenuItemMarkChar`로 체크 상태를 읽는다. 다만 **그 도구는 저장소에 없다** — 필요하면 다시
만들어야 한다 (`DockProbe`의 `verify`/`race`와 달리 이관하지 않았다). `NSOpenPanel`은 모달이라
자동화하면 세션이 막히므로 건드리지 않는다.

`SMAppService` 등록 상태는 메뉴 항목의 체크마크로 확인한다. `sfltool dumpbtm`은 토글 직후
응답이 멈추는 일이 있어 신뢰할 수 있는 판정 수단이 아니다.

## 서명과 권한

TCC 접근성 권한은 **코드 서명 + 번들 ID**에 묶인다. ad-hoc 서명(`codesign -s -`)을 쓰면 빌드마다
서명이 바뀌어 권한이 사라지고, 이후 모든 디버깅이 "권한이 날아간 것인지 코드가 틀린 것인지"
구분되지 않는다. `make-cert.sh`가 만드는 고정 self-signed 인증서를 쓰고 `/Applications` 고정 경로에
설치하는 이유다.

권한은 **프로세스 시작 시점에 고정된다.** 실행 중에 권한을 부여해도 그 프로세스에는 반영되지 않는다.
앱은 권한 여부(`permissions.isTrusted`)와 탭 생존 여부(`coordinator.isTapActive`)를 따로 노출하고,
권한은 있는데 탭이 없으면 메뉴바에 재실행을 안내한다.

배포 DMG는 자체 서명이라 내려받은 사용자는 첫 실행이 차단된다. **macOS 15부터 `우클릭 → 열기`
우회는 통하지 않는다** — 대화상자에 열기 버튼 자체가 없고 `휴지통으로 이동`이 가장 눈에 띈다.
설치 안내를 고칠 일이 있으면 이 점을 유지할 것. 직접 빌드한 앱에는 quarantine 속성이 붙지 않아
차단 자체가 없다.

## 문서

| 문서 | 내용 |
|---|---|
| `docs/superpowers/specs/2026-07-30-phase0-findings.md` | 플랫폼 동작 실측. 위 제약들의 근거 |
| `docs/superpowers/specs/2026-07-30-dock-click-minimize-design.md` | 설계, 폐기한 대안 |
| `docs/superpowers/specs/2026-07-30-verification.md` | 통과·미해결 항목. 재현되지 않은 1회성 실패 기록 포함 |
| `docs/superpowers/plans/2026-07-30-dock-minimizer.md` | 구현 계획 |

설계나 플랫폼 동작에 대한 새 발견이 있으면 findings 문서에 측정값과 함께 남긴다. 이 프로젝트는
플랫폼 동작을 추측하지 않고 합성 클릭으로 측정해 온 것이 핵심 자산이다.
