import AppKit
import CoreGraphics
import DockMinimizerCore
import os

/// 이벤트 탭의 수명을 관리한다.
///
/// 두 가지 방어 장치가 들어 있다.
/// 1. 전용 스레드의 런루프에서 돌린다. 메인 스레드가 SwiftUI 렌더링 등으로 막히면
///    탭 콜백이 지연되어 macOS가 탭을 죽이기 때문이다.
/// 2. kCGEventTapDisabledByTimeout / ByUserInput을 잡아 즉시 재활성화한다.
///    이 처리가 없으면 "한동안 잘 되다가 갑자기 멈추는" 증상이 나타난다.
final class EventTapController: @unchecked Sendable {
    /// 클릭 좌표와 수정자를 받아 판정을 돌려주는 콜백. 반드시 AX 호출 없이 즉시 반환해야 한다.
    typealias Decider = (CGPoint, ClickModifiers) -> Decision
    /// 판정 결과에 따른 실제 동작. 백그라운드로 비동기 디스패치된다.
    typealias Performer = (Decision) -> Void

    private let decide: Decider
    private let perform: Performer
    private let log = Logger(subsystem: "com.changhun.dockminimizer", category: "eventtap")

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    init(decide: @escaping Decider, perform: @escaping Performer) {
        self.decide = decide
        self.perform = perform
    }

    // MARK: - 수명

    func start() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.threadRunLoop = CFRunLoopGetCurrent()
            guard self.installTap() else { return }
            CFRunLoopRun()
        }
        thread.name = "com.changhun.dockminimizer.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = threadRunLoop {
            CFRunLoopStop(runLoop)
        }
        tap = nil
        runLoopSource = nil
        thread = nil
        threadRunLoop = nil
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }

        // 리슨 전용. 클릭을 삼키지 않으므로 Dock 상호작용을 절대 깨뜨리지 않는다.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("이벤트 탭 생성 실패. 접근성 권한을 확인하세요.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        log.info("이벤트 탭 시작 (listenOnly)")
        return true
    }

    // MARK: - 콜백
    //
    // 이 아래에서는 AX API를 절대 호출하지 않는다. 캐시 읽기와 산술 연산만 한다.

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 탭이 죽었을 때의 복구. 이 처리가 없으면 앱이 조용히 무력화된다.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.error("이벤트 탭이 비활성화됨 (type=\(type.rawValue)). 재활성화합니다.")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }

        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsedMicroseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000
            // 예산을 크게 밑돌아야 정상이다. 넘어가면 캐시 밖 호출이 섞여 든 것이다.
            if elapsedMicroseconds > 2_000 {
                log.error("콜백이 느립니다: \(elapsedMicroseconds)µs")
            }
        }

        let decision = decide(event.location, Self.modifiers(from: event.flags))
        if decision != .ignore {
            perform(decision)
        }
        // 리슨 전용이므로 항상 이벤트를 그대로 통과시킨다.
        return Unmanaged.passUnretained(event)
    }

    private static func modifiers(from flags: CGEventFlags) -> ClickModifiers {
        var result: ClickModifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }
}
