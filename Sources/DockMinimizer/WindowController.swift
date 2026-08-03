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
