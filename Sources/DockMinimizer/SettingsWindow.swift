// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import AppKit
import DockMinimizerCore
import SwiftUI

/// 설정 창의 상태를 SwiftUI에 노출하는 어댑터.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            // reloadFromSettings가 값을 밀어 넣을 때는 되쓰지 않는다.
            guard !isSyncing else { return }
            settings.isEnabled = isEnabled
            coordinator.settingsDidChange()
        }
    }
    @Published private(set) var exclusions: [String]

    let settings: DockMinimizerCore.Settings
    let permissions: PermissionsManager
    private let coordinator: Coordinator
    private var isSyncing = false

    init(
        settings: DockMinimizerCore.Settings,
        permissions: PermissionsManager,
        coordinator: Coordinator
    ) {
        self.settings = settings
        self.permissions = permissions
        self.coordinator = coordinator
        self.isEnabled = settings.isEnabled
        self.exclusions = settings.userExcludedBundleIDs.sorted()
    }

    /// 메뉴바에서 활성화를 토글하면 이 모델은 모르므로, 창을 열 때마다 실제 설정을 다시 읽는다.
    /// `Settings`가 유일한 진실이고 이 모델은 그 사본이다.
    func reloadFromSettings() {
        isSyncing = true
        isEnabled = settings.isEnabled
        isSyncing = false
        exclusions = settings.userExcludedBundleIDs.sorted()
    }

    func addExclusionViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "제외에 추가"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            settings.addExclusion(bundleID)
        }
        reload()
    }

    func remove(_ bundleID: String) {
        settings.removeExclusion(bundleID)
        reload()
    }

    private func reload() {
        reloadFromSettings()
        coordinator.settingsDidChange()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var permissions: PermissionsManager
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Dock 클릭으로 최소화 활성화", isOn: $model.isEnabled)
                .font(.headline)

            Divider()

            permissionSection

            Divider()

            exclusionSection
        }
        .padding(20)
        .frame(width: 420, height: 400)
    }

    @ViewBuilder
    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("접근성 권한").font(.headline)
            if permissions.isTrusted {
                Label("권한이 부여되었습니다", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("권한이 없어 동작하지 않습니다", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("시스템 설정 열기") {
                    permissions.openSystemSettings()
                }
            }
        }
    }

    @ViewBuilder
    private var exclusionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("제외할 앱").font(.headline)
            Text("Finder는 항상 제외됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(model.exclusions, id: \.self, selection: $selection) { bundleID in
                Text(bundleID)
            }
            .frame(minHeight: 140)

            HStack {
                Button("추가...") { model.addExclusionViaPanel() }
                Button("제거") {
                    if let selection { model.remove(selection) }
                }
                .disabled(selection == nil)
            }
        }
    }
}

/// 설정 창을 소유하는 컨트롤러. 창을 닫아도 앱이 종료되지 않도록 참조를 유지한다.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel
    private let permissions: PermissionsManager

    init(model: SettingsModel, permissions: PermissionsManager) {
        self.model = model
        self.permissions = permissions
    }

    func show() {
        // 메뉴바에서 바뀐 값이 있을 수 있으므로 열 때마다 실제 설정을 다시 읽는다.
        model.reloadFromSettings()
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(model: model, permissions: permissions)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "DockMinimizer 설정"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // LSUIElement 앱은 기본적으로 창을 앞으로 못 가져오므로 명시적으로 활성화한다.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
