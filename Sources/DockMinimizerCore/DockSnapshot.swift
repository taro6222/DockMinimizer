import CoreGraphics
import Foundation

/// Dock에 표시된 아이콘 하나. AX 트리에서 읽어 온 스냅샷 값이며 갱신 시점에 통째로 교체된다.
public struct DockItem: Equatable, Sendable {
    /// 전역 디스플레이 좌표. `CGEvent.location`과 같은 공간이어야 한다.
    public let frame: CGRect
    public let bundleID: String?
    public let title: String?

    public init(frame: CGRect, bundleID: String?, title: String?) {
        self.frame = frame
        self.bundleID = bundleID
        self.title = title
    }
}

/// 특정 시점의 Dock 아이콘 배치. 불변이므로 이벤트 탭 콜백에서 락 없이 읽을 수 있다.
public struct DockSnapshot: Equatable, Sendable {
    public let items: [DockItem]

    public static let empty = DockSnapshot(items: [])

    public init(items: [DockItem]) {
        self.items = items
    }

    /// 주어진 좌표를 포함하는 첫 아이콘. `CGRect.contains`는 왼쪽·위쪽 경계를
    /// 포함하고 오른쪽·아래쪽 경계를 제외하므로 인접 아이콘이 중복 매칭되지 않는다.
    public func item(at point: CGPoint) -> DockItem? {
        items.first { $0.frame.contains(point) }
    }
}
