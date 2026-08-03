import AppKit
import Combine
import DockMinimizerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    let permissions = PermissionsManager()
    private(set) var coordinator: Coordinator?
    private var menuBar: MenuBarController?
    private var permissionSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = Coordinator(settings: settings)
        self.coordinator = coordinator

        menuBar = MenuBarController(
            settings: settings,
            permissions: permissions,
            coordinator: coordinator
        )

        // 권한 상태 전환을 구독한다. startMonitoring 보다 먼저 구독해야
        // 초기 상태 변화를 놓치지 않는다.
        permissionSubscription = permissions.$isTrusted
            .removeDuplicates()
            .sink { [weak self] trusted in
                guard let self else { return }
                if trusted {
                    self.coordinator?.start()
                } else {
                    self.coordinator?.stop()
                    self.permissions.requestAccess()
                }
            }

        permissions.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionSubscription = nil
        coordinator?.stop()
        permissions.stopMonitoring()
    }
}
