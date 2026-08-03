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
