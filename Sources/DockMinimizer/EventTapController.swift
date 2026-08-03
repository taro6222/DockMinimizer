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

    /// mouseDown을 삼킨 시각(uptime 나노초). 탭 스레드에서만 접근한다.
    ///
    /// 시각을 함께 들고 있는 이유: 짝이 되는 mouseUp이 끝내 오지 않을 수 있다
    /// (제스처 도중 탭이 비활성화되거나, 마스크 밖에서 제스처가 끝나는 경우).
    /// 불리언만 두면 그 플래그가 남아 한참 뒤의 무관한 클릭을 삼킨다.
    private var swallowedDownAt: UInt64?
    private static let swallowWindow: UInt64 = 1_000_000_000  // 1초

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
        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)
        )

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }

        // 액티브 탭. 우리가 개입하는 클릭은 삼켜야 한다.
        //
        // 리슨 전용으로는 동작하지 않는다. 클릭이 Dock에도 전달되면, 우리가 최소화한
        // 직후 Dock이 같은 클릭을 처리하면서 윈도우를 원상복구한다(100ms 이내로 측정됨).
        // Phase 0에서 "Dock은 아무 것도 하지 않는다"고 본 것은 되돌릴 대상이 없을 때의
        // 관찰이었고, 우리 동작과 겹칠 때의 반응은 그것과 다르다.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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
        log.info("이벤트 탭 시작 (defaultTap — 개입한 클릭은 삼킨다)")
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
        // mouseDown을 삼켰다면 짝이 되는 mouseUp도 삼켜야 Dock이 이상 상태에 빠지지 않는다.
        if type == .leftMouseUp {
            if let downAt = swallowedDownAt {
                swallowedDownAt = nil
                if DispatchTime.now().uptimeNanoseconds - downAt < Self.swallowWindow {
                    return nil
                }
            }
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
        guard decision != .ignore else { return Unmanaged.passUnretained(event) }

        perform(decision)
        // 삼키지 않으면 Dock이 같은 클릭을 처리하며 우리 동작을 원상복구한다.
        //
        // 알려진 대가: 프론트모스트 앱 아이콘은 mouseDown이 Dock에 닿지 않으므로
        // 드래그로 재배열할 수 없다. 드래그를 살리려면 mouseDown을 통과시켜야 하는데,
        // 그러면 Dock이 우리 최소화를 되돌린다. 둘을 동시에 만족시킬 수 없다.
        swallowedDownAt = DispatchTime.now().uptimeNanoseconds
        return nil
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
