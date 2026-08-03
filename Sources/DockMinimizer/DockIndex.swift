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
