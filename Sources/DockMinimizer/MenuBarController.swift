import AppKit
import DockMinimizerCore
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settings: Settings
    private let permissions: PermissionsManager
    private let coordinator: Coordinator
    private let settingsWindow: SettingsWindowController
    private let model: SettingsModel

    private let enabledItem = NSMenuItem(title: "활성화", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 시작", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let relaunchItem = NSMenuItem(title: "재실행", action: nil, keyEquivalent: "")

    init(settings: Settings, permissions: PermissionsManager, coordinator: Coordinator) {
        self.settings = settings
        self.permissions = permissions
        self.coordinator = coordinator
        self.model = SettingsModel(
            settings: settings, permissions: permissions, coordinator: coordinator
        )
        self.settingsWindow = SettingsWindowController(model: model, permissions: permissions)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "dock.arrow.down.rectangle",
            accessibilityDescription: "DockMinimizer"
        )
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        enabledItem.target = self
        enabledItem.action = #selector(toggleEnabled)
        menu.addItem(enabledItem)

        loginItem.target = self
        loginItem.action = #selector(toggleLoginItem)
        menu.addItem(loginItem)

        relaunchItem.target = self
        relaunchItem.action = #selector(relaunch)
        menu.addItem(relaunchItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "설정...", action: #selector(openSettings), keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    /// 메뉴가 열릴 때마다 실제 상태를 다시 읽어 체크마크를 맞춘다.
    func menuWillOpen(_ menu: NSMenu) {
        enabledItem.state = settings.isEnabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if DockIndex.isDockMagnificationEnabled {
            // 확대 중에는 DockIndex가 빈 스냅샷을 내보내 기능이 멈춘다. 그 이유를 알린다.
            permissionItem.title = "Dock 확대가 켜져 있어 일시 중지됨"
        } else if !permissions.isTrusted {
            permissionItem.title = "접근성 권한 없음 — 설정에서 허용 필요"
        } else if !coordinator.isTapActive {
            // 권한은 있는데 탭이 없다. TCC 권한은 프로세스 시작 시점에 고정될 수 있어,
            // 실행 중에 권한을 부여하면 재실행해야 반영된다 (실측 확인).
            permissionItem.title = "권한 부여됨 — 재실행해야 적용됩니다"
        } else {
            permissionItem.title = "접근성 권한: 정상"
        }
        relaunchItem.isHidden = permissions.isTrusted && coordinator.isTapActive
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        coordinator.settingsDidChange()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인 항목 설정에 실패했습니다"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    /// 실행 중에 부여된 접근성 권한을 적용하려면 프로세스를 다시 띄워야 한다.
    @objc private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
