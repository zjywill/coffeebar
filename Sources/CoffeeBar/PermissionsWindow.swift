import AppKit
import SwiftUI

/// 一项权限：怎么检查、怎么申请、去哪个设置页（照 Thaw 的 Permission）。
@MainActor
final class Permission: ObservableObject, Identifiable {
    let id: String
    let title: String
    let iconName: String
    let iconColor: Color
    let details: [String]
    /// 没有它 App 就没法工作（辅助功能）；可选的（屏幕录制）缺了只是功能受限。
    let isRequired: Bool
    private let settingsURL: URL?
    private let check: () -> Bool
    private let request: () -> Void
    @Published private(set) var hasPermission: Bool
    private var timer: Timer?

    init(id: String, title: String, iconName: String, iconColor: Color, details: [String], isRequired: Bool,
         settingsURL: URL?, check: @escaping () -> Bool, request: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.iconColor = iconColor
        self.details = details
        self.isRequired = isRequired
        self.settingsURL = settingsURL
        self.check = check
        self.request = request
        hasPermission = check()
    }

    /// 每 3 秒查一次，直到拿到权限为止（Thaw 的 configureCancellables）。
    func startPolling() {
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let granted = check()
        if granted != hasPermission { hasPermission = granted }
        if granted { stopPolling() }
    }

    /// 弹系统授权框，同时打开对应的设置页：用户在系统框里点了"拒绝"之后，设置页是唯一能再开的地方。
    func performRequest() {
        startPolling()
        request()
        if let settingsURL { NSWorkspace.shared.open(settingsURL) }
    }
}

extension Permission {
    static func accessibility() -> Permission {
        Permission(id: "accessibility", title: L("Accessibility"), iconName: "accessibility", iconColor: .blue,
                   details: [L("Identify which app each hidden menu bar item belongs to."),
                             L("Move menu bar items to hide or reveal them."),
                             L("Open a hidden item's menu when you click it in the panel.")],
                   isRequired: true,
                   settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
                   check: { Permissions.hasAccessibility },
                   request: { Permissions.requestAccessibility() })
    }

    static func screenRecording() -> Permission {
        Permission(id: "screenRecording", title: L("Screen Recording"), iconName: "record.circle", iconColor: .red,
                   details: [L("Show the real menu bar icons in the panel, with unread badges and readings."),
                             L("Optional. Without it the panel shows app icons instead.")],
                   isRequired: false,
                   settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
                   check: { ItemCapture.hasPermission },
                   request: { ItemCapture.requestPermission() })
    }
}

/// 权限引导窗口（照 Thaw 的 PermissionsView）。首次启动必经；之后辅助功能权限丢了、或者用户从菜单里打开时再弹。
@MainActor
final class PermissionsWindowController {
    static let shared = PermissionsWindowController()
    private static let firstLaunchKey = "CoffeeBar.hasCompletedFirstLaunch"

    let accessibility = Permission.accessibility()
    let screenRecording = Permission.screenRecording()
    private var window: NSWindow?
    private var wasAccessory = true

    var isFirstLaunch: Bool { !UserDefaults.standard.bool(forKey: Self.firstLaunchKey) }

    /// 启动时：新用户、或者辅助功能权限没了，就弹窗。
    func showIfNeeded() {
        if isFirstLaunch || !accessibility.hasPermission { show() }
    }

    func show() {
        accessibility.startPolling()
        screenRecording.startPolling()
        if window == nil {
            let view = PermissionsView(controller: self)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.center()
            self.window = window
        }
        // 菜单栏 App 没有 Dock 图标，要临时切成普通 App 才能把窗口拉到前台。
        wasAccessory = NSApp.activationPolicy() == .accessory
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refocus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.firstLaunchKey)
        accessibility.stopPolling()
        screenRecording.stopPolling()
        window?.orderOut(nil)
        if wasAccessory { NSApp.setActivationPolicy(.accessory) }
    }

    /// 屏幕录制权限有时要重启 App 才生效。
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

private struct PermissionsView: View {
    let controller: PermissionsWindowController
    @ObservedObject private var accessibility: Permission
    @ObservedObject private var screenRecording: Permission

    init(controller: PermissionsWindowController) {
        self.controller = controller
        accessibility = controller.accessibility
        screenRecording = controller.screenRecording
    }

    private var hasAll: Bool { accessibility.hasPermission && screenRecording.hasPermission }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(L("Enable Permissions")).font(.largeTitle.weight(.semibold))
                Text(L("CoffeeBar needs the permissions below to manage your menu bar."))
                Text(L("Everything stays on your Mac. Nothing is collected or sent anywhere."))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                PermissionCard(permission: accessibility, controller: controller)
                PermissionCard(permission: screenRecording, controller: controller)
            }
            .fixedSize(horizontal: false, vertical: true)

            Label {
                Text(L("CoffeeBar works without Screen Recording; the panel just shows app icons instead of the real ones."))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.shield").foregroundStyle(.green)
            }
            .font(.subheadline)

            HStack(spacing: 12) {
                Button { NSApp.terminate(nil) } label: { Text(L("Quit")).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button { controller.finish() } label: {
                    Text(hasAll ? L("Continue") : L("Continue in Limited Mode"))
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(hasAll ? AnyShapeStyle(.primary) : AnyShapeStyle(.yellow))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!accessibility.hasPermission)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 640)
    }
}

private struct PermissionCard: View {
    @ObservedObject var permission: Permission
    let controller: PermissionsWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(permission.title).font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: permission.iconName).font(.title2).foregroundStyle(permission.iconColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(permission.details, id: \.self) { detail in
                    Label { Text(detail) } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
            Button {
                permission.performRequest()
            } label: {
                if permission.hasPermission {
                    Label(L("Permission Granted"), systemImage: "checkmark").frame(maxWidth: .infinity)
                } else {
                    Text(L("Grant Permission")).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(permission.hasPermission ? .green : .accentColor)
            .allowsHitTesting(!permission.hasPermission)
            if !permission.hasPermission {
                // 系统框里点了"拒绝"以后，系统不会再弹；只能去设置里手动开。屏幕录制开了之后有时还要重启。
                Text(permission.isRequired
                     ? L("If you already declined, turn it on in System Settings, then come back here.")
                     : L("If you already declined, turn it on in System Settings. macOS may require relaunching CoffeeBar."))
                    .font(.caption).foregroundStyle(.secondary)
                if !permission.isRequired {
                    Button(L("Relaunch CoffeeBar")) { controller.relaunch() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
        .onChange(of: permission.hasPermission) { granted in
            if granted { controller.refocus() }
        }
    }
}
