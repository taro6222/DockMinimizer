# DockMinimizer

[![Release](https://img.shields.io/github/v/release/taro6222/DockMinimizer?label=release)](https://github.com/taro6222/DockMinimizer/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/taro6222/DockMinimizer/releases/latest)

활성 상태인 앱의 Dock 아이콘을 클릭하면 그 앱의 윈도우를 최소화하는 macOS 메뉴바 앱.

```
메모가 활성 상태 → Dock의 메모 아이콘 클릭 → 윈도우 최소화
                → 한 번 더 클릭          → 복원
다른 앱의 아이콘 클릭                     → 평소대로 활성화
```

macOS 기본 동작에서 이 클릭은 아무 일도 하지 않는다. 그 빈 동작을 최소화 토글로 쓴다.

## 설치

**[최신 릴리스에서 DMG 내려받기](https://github.com/taro6222/DockMinimizer/releases/latest)** →
`DockMinimizer.app`을 `Applications`로 끌어다 놓기 → **아래 두 단계 필수.**

### 1. 첫 실행 차단 해제

자체 서명이라 macOS가 실행을 막는다. `열지 않음` 대화상자에서 **`휴지통으로 이동`을 누르지 말고**
`완료`로 닫은 뒤, 둘 중 하나를 한다.

- **시스템 설정 › 개인정보 보호 및 보안**을 열고 아래로 스크롤 → `...을(를) 차단했습니다` 옆의
  열기 버튼 → 암호 또는 Touch ID
- 또는 `xattr -dr com.apple.quarantine /Applications/DockMinimizer.app`

macOS 15부터 예전의 `우클릭 → 열기`는 통하지 않는다. 대화상자에 열기 버튼 자체가 없다.

### 2. 접근성 권한

**시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용**에서 `+`로
`/Applications/DockMinimizer.app` 추가 후 켠다. 없으면 아무 동작도 하지 않는다.

켠 뒤에도 동작하지 않으면 메뉴바에 `권한 부여됨 — 재실행해야 적용됩니다`가 뜬다. `재실행`을 누른다.
macOS가 앱 시작 시점에 권한을 고정하기 때문이다.

## 사용

메뉴바 아이콘에서 켜기/끄기, 제외할 앱, 로그인 시 시작을 설정한다.
Finder와 이 앱 자신은 항상 제외된다. Dock에는 이 앱의 아이콘이 생기지 않는다.

**제거** — 메뉴바에서 종료 → `/Applications/DockMinimizer.app` 삭제 → 손쉬운 사용 목록에서 제거.

## 소스에서 빌드

```bash
git clone https://github.com/taro6222/DockMinimizer.git
cd DockMinimizer
./Scripts/make-cert.sh   # 최초 1회. 고정 코드서명 인증서
./Scripts/install.sh     # 빌드 → 설치 → 실행
```

macOS 14 이상과 Swift 6 툴체인이 필요하다. 배포용 DMG는 `./Scripts/make-dmg.sh`.

직접 빌드한 앱에는 quarantine 속성이 붙지 않아 **위 1번(차단 해제)이 필요 없다.**
차단을 부르는 것은 서명이 아니라 내려받은 파일에 붙는 속성이기 때문이다.

고정 인증서를 쓰므로 재빌드해도 접근성 권한이 유지된다.
ad-hoc 서명(`codesign -s -`)은 빌드마다 서명이 바뀌어 권한이 사라진다.

## 알려진 제약

| 제약 | 이유 |
|---|---|
| 활성 앱의 Dock 아이콘은 드래그로 재배열 불가 | 그 클릭을 삼켜야 최소화가 동작한다. 다른 아이콘은 영향 없음 |
| Dock 확대가 켜지면 기능 일시 중지 | AX 프레임이 확대를 반영하지 않아 히트테스트가 어긋날 수 있다. 메뉴바에 사유 표시 |
| 내려받은 앱은 첫 실행이 차단됨 | 자체 서명. 없애려면 Developer ID + 공증($99/년)이 필요하다 |
| App Store 배포 불가 | 샌드박스가 이벤트 탭 생성을 금지한다 |

## 구조

판정 로직 전체가 `DockMinimizerCore`의 순수 함수 `ClickRouter.decide`에 모여 있고 단위 테스트로
고정되어 있다. 나머지 모듈은 그 함수에 넣을 입력을 준비하고 결과를 실행한다.

세 가지 플랫폼 동작이 이 코드의 모양을 결정한다. 전부 [실측](docs/superpowers/specs/2026-07-30-phase0-findings.md)으로
확인한 것이고, 배경을 모르면 버그처럼 보이므로 **"고치기" 전에 그 문서를 읽을 것.**

**1. 이벤트 탭 콜백에서 AX를 호출하지 않는다.**
Dock AX 조회는 수십 ms가 걸리는 IPC다. 콜백이 지연되면 macOS가 탭을 조용히 죽인다 —
증상은 "한동안 잘 되다가 갑자기 멈춤"이고 오류는 남지 않는다. 그래서 `DockIndex`와
`AppStateCache`가 모든 조회를 백그라운드에서 미리 해 불변 스냅샷으로 캐싱한다.

**2. 개입하는 클릭은 삼켜야 한다.**
리슨 전용 탭으로는 동작하지 않는다. 클릭이 Dock에도 가면 우리가 최소화한 직후 Dock이
100ms 안에 되돌린다. `AXUIElementSetAttributeValue`는 `.success`를 반환하고 로그도 정상이라
증상은 "아무 일도 일어나지 않음"으로만 보인다.

**3. 복원도 이 앱이 직접 한다.**
윈도우를 전부 최소화해도 앱은 프론트모스트로 남는데, 그 상태에서는 Dock 아이콘을 눌러도
복원되지 않는다. Dock의 기본 동작에 기대면 사용자가 앱을 되살릴 수 없다.

부수적으로, 최소화하면 Dock에 아이콘이 하나 늘어 **모든 아이콘의 x좌표가 22.5pt 밀린다.**
어떤 알림으로도 통보되지 않아 동작 직후 `DockIndex`를 직접 갱신한다. 그리고 윈도우를
최소화하면 subrole이 `AXStandardWindow`에서 `AXDialog`로 바뀌므로 subrole로 필터하면 안 된다.

## 개발

```bash
swift build
swift test                   # 순수 로직 24개

swift run DockProbe          # Dock AX 트리 덤프
swift run DockProbe verify   # 설치된 앱 동작 검증 11개
swift run DockProbe ui       # 메뉴바·설정 창·로그인 항목 15개
swift run DockProbe race     # 리슨 전용 탭 회귀 테스트 (앱을 끄고 실행)

log show --predicate 'subsystem == "com.changhun.dockminimizer"' --last 10m --info --debug
```

Dock이나 이벤트 탭 코드를 고쳤다면 `verify`와 `race`를, 메뉴바나 설정 창을 고쳤다면 `ui`를 돌릴 것.
`race`는 위 구조 2번이 여전히 유효한지 확인한다.

## 문서

플랫폼 동작을 추측하지 않고 합성 클릭으로 전부 측정한 뒤 구현했다. 그 과정에서 위 세 가지를
찾았고, 측정값과 함께 기록해 두었다.

| 문서 | 내용 |
|---|---|
| [설계](docs/superpowers/specs/2026-07-30-dock-click-minimize-design.md) | 아키텍처, 판정 로직, 폐기한 대안 |
| [실측 결과](docs/superpowers/specs/2026-07-30-phase0-findings.md) | macOS Dock 동작 측정. 구조 절의 근거 |
| [검증 기록](docs/superpowers/specs/2026-07-30-verification.md) | 통과·미해결 항목 |
| [구현 계획](docs/superpowers/plans/2026-07-30-dock-minimizer.md) | 단계별 작업 계획 |

## 라이선스

[GPL-3.0-or-later](LICENSE)

쓰는 데는 제약이 없다. 개인이든 업무용이든 자유롭게 쓰고 고칠 수 있다.
제약은 **배포할 때** 생긴다 — 이 코드로 만든 것을 배포하려면 전체 소스를 같은 GPL로 공개해야 한다.

기여는 환영한다. PR을 보내면 그 코드도 GPL-3.0-or-later로 제공하는 데 동의하는 것으로 본다.
