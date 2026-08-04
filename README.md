# DockMinimizer

[![Release](https://img.shields.io/github/v/release/taro6222/DockMinimizer?label=release)](https://github.com/taro6222/DockMinimizer/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/taro6222/DockMinimizer/releases/latest)

활성 상태인 앱의 Dock 아이콘을 클릭하면 그 앱의 윈도우를 최소화하는 macOS 메뉴바 앱.
한 번 더 클릭하면 복원된다.

```
메모가 활성 상태 → Dock의 메모 아이콘 클릭 → 윈도우가 최소화
                → 한 번 더 클릭         → 윈도우가 복원
다른 앱의 아이콘 클릭                     → 평소대로 활성화 (개입하지 않음)
```

macOS 기본 동작에서 이 클릭은 아무 일도 하지 않는다. 그 빈 동작을 최소화 토글로 쓴다.

## 설치

**[최신 릴리스에서 DMG 내려받기](https://github.com/taro6222/DockMinimizer/releases/latest)**

DMG를 열고 `DockMinimizer.app`을 `Applications` 폴더로 끌어다 놓는다.
아래 두 단계를 건너뛰면 동작하지 않으니 반드시 확인할 것.

### 1. 첫 실행 — 차단 해제

내려받은 앱은 자체 서명이라 macOS가 실행을 막는다. `열지 않음` 대화상자가 뜨는데
**`휴지통으로 이동`을 누르지 말 것.** `완료`로 닫고 아래 중 하나를 하면 된다.

**방법 1 — 시스템 설정**

**시스템 설정 › 개인정보 보호 및 보안**을 열고 아래로 스크롤하면
`Mac을 보호하기 위해 'DockMinimizer.app'을(를) 차단했습니다` 안내가 있다.
그 옆의 열기 버튼을 누르고 암호 또는 Touch ID로 확인한다.

**방법 2 — 터미널**

```bash
xattr -dr com.apple.quarantine /Applications/DockMinimizer.app
```

macOS 15부터 예전의 `우클릭 → 열기` 우회는 통하지 않는다. 대화상자에 열기 버튼 자체가 없다
(macOS 26에서 확인).

> **소스에서 직접 빌드하면 이 과정이 전혀 필요 없다.** 차단을 부르는 것은 서명이 아니라
> 내려받은 파일에 붙는 `com.apple.quarantine` 속성이고, 로컬에서 빌드한 앱에는 그 속성이
> 붙지 않는다. 아래 [소스에서 빌드](#소스에서-빌드) 참조.

### 2. 접근성 권한 — 필수

**시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용**에서 `+` 버튼으로
`/Applications/DockMinimizer.app`을 추가하고 켠다.

이 권한이 없으면 설치는 되지만 아무 동작도 하지 않는다. Dock 클릭을 감지하고
다른 앱의 윈도우를 최소화하는 데 필요하다.

권한을 켠 뒤에도 동작하지 않으면 메뉴바에 `권한 부여됨 — 재실행해야 적용됩니다`가
표시된다. `재실행`을 누르면 된다. TCC 권한이 프로세스 시작 시점에 고정되기 때문이며,
실측에서 재현되는 동작이다.

### 제거

메뉴바에서 종료 → `/Applications/DockMinimizer.app` 삭제 → 손쉬운 사용 목록에서도 제거.

## 소스에서 빌드

macOS 14 이상, Swift 6 툴체인(Xcode 또는 Command Line Tools)이 필요하다.

```bash
git clone https://github.com/taro6222/DockMinimizer.git
cd DockMinimizer
./Scripts/make-cert.sh   # 최초 1회. 고정 코드서명 인증서를 만든다
./Scripts/install.sh     # 빌드 → /Applications 설치 → 실행
```

배포용 DMG를 만들려면 `./Scripts/make-dmg.sh`.

`make-cert.sh`로 만든 고정 인증서를 쓰기 때문에 재빌드해도 접근성 권한이 유지된다.
ad-hoc 서명(`codesign -s -`)을 쓰면 빌드마다 서명이 바뀌어 권한이 사라진다.
직접 빌드한 앱에는 quarantine 속성이 붙지 않으므로 위 1번(차단 해제)이 필요 없다.

## 사용

메뉴바 아이콘에서 활성화 여부, 로그인 시 시작, 설정 창을 제어한다.
설정 창에서 특정 앱을 제외 목록에 넣을 수 있다. Finder와 이 앱 자신은 항상 제외된다.

## 개발

```bash
swift build                # 빌드
swift test                 # 순수 로직 테스트 (24개)
swift run DockProbe        # Dock AX 트리 덤프
swift run DockProbe watch  # 클릭과 아이콘 매칭 실시간 관찰
swift run DockProbe experiment "메모" com.apple.Notes   # 좌표계·확대·Dock 동작 자동 실측
```

설치된 앱의 실동작 검증:

```bash
swift run DockProbe verify   # 11개 항목 (토글, 연속 클릭, 수정자 키, Dock 재정렬)
swift run DockProbe race     # 리슨 전용 탭 회귀 테스트 — 앱을 끄고 실행할 것
```

Dock이나 이벤트 탭 관련 코드를 고쳤다면 두 가지 모두 다시 돌릴 것. `race`는 아래
구조 절의 2번이 여전히 유효한지 확인한다.

로그 확인:

```bash
log show --predicate 'subsystem == "com.changhun.dockminimizer"' --last 10m --info --debug
```

## 구조

판정 로직 전체가 `DockMinimizerCore`의 순수 함수 `ClickRouter.decide`에 모여 있고
단위 테스트로 고정되어 있다. 나머지 모듈은 그 함수에 넣을 입력을 준비하고 결과를 실행한다.

세 가지 제약이 이 코드의 모양을 결정한다. 셋 다 실측으로 확인한 것이고, 배경을 모르면
버그처럼 보이므로 "고치기" 전에 `docs/superpowers/specs/2026-07-30-phase0-findings.md`를
먼저 읽을 것.

**1. 이벤트 탭 콜백에서 AX API를 호출하지 않는다.**
Dock AX 조회는 수십 밀리초가 걸리는 IPC이고, 콜백이 지연되면 macOS가
`kCGEventTapDisabledByTimeout`으로 탭을 조용히 죽인다. 증상은 "한동안 잘 되다가 갑자기
멈춤"이고 아무 오류도 남지 않는다. `DockIndex`와 `AppStateCache`가 모든 AX 조회를
백그라운드에서 미리 수행해 불변 스냅샷으로 캐싱하는 이유다.

**2. 개입하는 클릭은 삼켜야 한다.**
리슨 전용 탭으로는 동작하지 않는다. 클릭이 Dock에도 전달되면, 우리가 최소화한 직후
Dock이 같은 클릭을 처리하며 100ms 안에 윈도우를 원상복구한다. `AXUIElementSetAttributeValue`는
`.success`를 반환하고 로그도 정상이라 증상은 "아무 일도 일어나지 않음"으로만 보인다.
대가로 **프론트모스트 앱의 아이콘은 드래그로 재배열할 수 없다.** 다른 아이콘은 영향이 없다.

**3. 복원도 이 앱이 직접 한다.**
Dock은 프론트모스트 앱의 윈도우가 전부 최소화된 상태에서 아이콘을 클릭해도 아무 일도 하지
않는다. 윈도우를 최소화해도 앱은 프론트모스트로 남으므로, Dock의 기본 복원에 기대면
사용자가 앱을 되살릴 수 없다. `ClickRouter`가 최소화·복원·무시의 3분기로 판정한다.

부수적으로 두 가지가 더 있다.

- 최소화하면 Dock에 아이콘이 하나 추가되고, 가운데 정렬이 다시 계산되어 **모든 아이콘의
  x좌표가 22.5pt 밀린다.** 어떤 시스템 알림으로도 통보되지 않으므로 동작 직후
  `DockIndex`를 직접 갱신한다. 그러지 않으면 다음 클릭이 이웃 앱을 최소화한다
- 윈도우를 최소화하면 subrole이 `AXStandardWindow`에서 `AXDialog`로 바뀐다. subrole로
  필터하면 최소화된 윈도우를 찾지 못해 복원이 되지 않는다. `AXMinimized` 속성 보유를
  기준으로 삼는다

## 알려진 제약

- **App Store 배포 불가.** 샌드박스가 이벤트 탭 생성을 금지한다
- **자체 서명이라 내려받은 앱은 첫 실행이 차단된다.** 위 [차단 해제](#1-첫-실행--차단-해제)로 우회한다.
  경고 없이 배포하려면 Apple Developer Program($99/년)의 Developer ID 인증서로 서명하고
  `notarytool`로 공증한 뒤 `stapler`로 티켓을 붙여야 한다. `Scripts/bundle.sh`의
  `DOCKMINIMIZER_CERT` 환경 변수로 인증서를 바꿀 수 있다. 무료 Apple ID로 받는
  `Apple Development` 인증서는 배포에 도움이 되지 않는다 — Gatekeeper는 Developer ID와
  공증만 신뢰한다. 서명 주체를 바꾸면 기존 사용자의 접근성 권한이 초기화되는 점도 감안할 것
- **접근성 권한 필수**
- **프론트모스트 앱 아이콘은 드래그 재배열 불가** (위 2번)
- **Dock 확대가 켜져 있으면 기능이 일시 중지된다.** AX 프레임이 확대를 반영하지 않아
  히트테스트가 어긋날 수 있고, 어긋남의 크기를 측정하지 못했다. 오작동보다 중지를 택했다.
  메뉴바에 그 사유가 표시된다

## 라이선스

[GNU General Public License v3.0 or later](LICENSE)

쓰는 데는 아무 제약이 없다. 개인이든 회사든, 무료든 업무용이든 자유롭게 쓰고 고칠 수 있다.

제약은 **배포할 때** 생긴다. 이 코드를 사용해 만든 것을 남에게 배포하려면 전체 소스를
같은 GPL-3.0 이상으로 공개해야 한다. 코드를 가져다 비공개 제품에 넣어 파는 일은
이 조건 때문에 사실상 불가능하다.

기여는 환영한다. PR을 보내면 그 코드도 GPL-3.0-or-later로 제공하는 데 동의하는 것으로 본다.

## 문서

| 문서 | 내용 |
|---|---|
| [설계](docs/superpowers/specs/2026-07-30-dock-click-minimize-design.md) | 아키텍처와 판정 로직, 대안과 폐기 사유 |
| [실측 결과](docs/superpowers/specs/2026-07-30-phase0-findings.md) | macOS Dock의 실제 동작 측정. 위 구조 절의 근거 |
| [검증 기록](docs/superpowers/specs/2026-07-30-verification.md) | 통과 항목, 남은 항목, 미해결 이슈 |
| [구현 계획](docs/superpowers/plans/2026-07-30-dock-minimizer.md) | 단계별 작업 계획 |

플랫폼 동작을 추측하지 않고 전부 합성 클릭으로 측정한 뒤 구현했다. 그 과정에서 Dock이
프론트모스트 앱을 복원하지 않는다는 것, 최소화가 Dock 폭을 바꿔 모든 아이콘을 22.5pt
밀어낸다는 것, 리슨 전용 탭으로는 Dock이 우리 최소화를 되돌린다는 것을 찾았다.
셋 다 문서에 측정값과 함께 기록되어 있다.
