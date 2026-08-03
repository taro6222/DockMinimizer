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
