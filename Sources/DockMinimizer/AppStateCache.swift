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
