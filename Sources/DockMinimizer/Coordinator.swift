// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import AppKit
import DockMinimizerCore
import os

/// 캐시, 판정, 실행을 잇는 조립부.
final class Coordinator: @unchecked Sendable {
    private let settings: Settings
    private let dockIndex = DockIndex()
    private let appState = AppStateCache()
    private let work = DispatchQueue(label: "com.changhun.dockminimizer.work")
    private let log = Logger(subsystem: "com.changhun.dockminimizer", category: "coordinator")

    /// 설정이 바뀔 때만 갱신되는, 콜백에서 읽기 전용으로 쓰는 스냅샷.
    private let cachedSettings = OSAllocatedUnfairLock(
        initialState: (isEnabled: true, excluded: Set<String>())
    )

    private var tapController: EventTapController?
    private var isRunning = false

    /// 권한이 있어도 탭이 살아 있지 않을 수 있다. 메뉴바가 그 차이를 사용자에게 알린다.
    var isTapActive: Bool { tapController?.isActive ?? false }

    init(settings: Settings) {
        self.settings = settings
    }

    func settingsDidChange() {
        cachedSettings.withLock {
            $0 = (settings.isEnabled, settings.excludedBundleIDs)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        settingsDidChange()
        dockIndex.start()
        appState.start()

        let controller = EventTapController(
            decide: { [weak self] point, modifiers in
                guard let self else { return .ignore }
                let settings = self.cachedSettings.withLock { $0 }
                return ClickRouter.decide(RouterInput(
                    point: point,
                    modifiers: modifiers,
                    snapshot: self.dockIndex.snapshot,
                    frontmost: self.appState.frontmost,
                    isEnabled: settings.isEnabled,
                    excludedBundleIDs: settings.excluded
                ))
            },
            perform: { [weak self] decision in
                self?.perform(decision)
            }
        )
        controller.start()
        tapController = controller
        log.info("Coordinator 시작")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tapController?.stop()
        tapController = nil
        dockIndex.stop()
        appState.stop()
        log.info("Coordinator 중지")
    }

    /// 이벤트 탭 콜백에서 호출되지만 즉시 비동기로 빠져나간다.
    /// AX 호출은 전부 이 큐 위에서 일어난다.
    private func perform(_ decision: Decision) {
        switch decision {
        case .ignore:
            break

        case .minimize(let pid):
            work.async { [weak self] in
                guard let self else { return }
                let count = WindowController.minimize(pid: pid)
                if count > 0 {
                    self.appState.markMinimized(pid: pid)
                    // 최소화된 윈도우가 Dock에 아이콘으로 추가되면 Dock 폭이 바뀌고
                    // 모든 아이콘의 x좌표가 밀린다. 갱신하지 않으면 다음 클릭이
                    // 이웃 앱을 최소화한다.
                    self.dockIndex.refreshAfterWindowChange()
                }
                self.log.info("최소화 pid=\(pid) 윈도우=\(count)개")
            }

        case .restore(let pid):
            work.async { [weak self] in
                guard let self else { return }
                let count = WindowController.restore(pid: pid)
                if count > 0 {
                    self.appState.markRestored(pid: pid)
                    self.dockIndex.refreshAfterWindowChange()
                }
                self.log.info("복원 pid=\(pid) 윈도우=\(count)개")
            }
        }
    }
}
