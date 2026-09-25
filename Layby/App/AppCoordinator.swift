import AppKit
import Observation
import SwiftUI
import os

@Observable @MainActor
final class AppCoordinator: NSObject, NSWindowDelegate {
    let settings = AppSettings()
    let store = ShelfStore()
    private(set) var hotKeyMessage: String?
    private(set) var launchAtLoginEnabled = false
    private(set) var launchAtLoginNeedsApproval = false
    private(set) var launchAtLoginMessage: String?
    @ObservationIgnored private let launchAtLogin: LaunchAtLoginManaging
    @ObservationIgnored private(set) lazy var observation = DragObservationService(settings: settings, store: store)
    @ObservationIgnored private lazy var hotKey = GlobalHotKeyService()
    @ObservationIgnored private lazy var notch = NotchDropController(store: store, settings: settings)
    @ObservationIgnored private lazy var shelf = ShelfWindowController(store: store, settings: settings)
    @ObservationIgnored private lazy var updates = UpdateService()
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingHide: Task<Void, Never>?
    @ObservationIgnored private var dragActivated = false
    @ObservationIgnored private var automaticPresentation = false

    init(launchAtLogin: LaunchAtLoginManaging? = nil) {
        self.launchAtLogin = launchAtLogin ?? LaunchAtLoginService()
        super.init()
        refreshLaunchAtLoginStatus()
    }

    func start() {
        L10n.configure(settings.language)
        _ = updates
        installMenus()
        settings.onChange = { [weak self] in self?.applySettings() }
        hotKey.onPress = { [weak self] in self?.showShelf() }
        observation.onActivation = { [weak self] reason, point in self?.activate(reason, point: point) }
        observation.onActivityChange = { [weak self] active in self?.dragActivityChanged(active) }
        notch.hasShelfOnScreen = { [weak self] screen in
            self?.shelf.isVisible(on: screen.frame) ?? false
        }
        notch.onActivate = { [weak self] screen in
            self?.activate(.notch, point: CGPoint(x: screen.frame.midX, y: screen.frame.maxY), screen: screen)
        }
        notch.onReceive = { [weak self] screen in
            self?.activate(.notch, point: CGPoint(x: screen.frame.midX, y: screen.frame.maxY), screen: screen)
            self?.automaticPresentation = false
            self?.dragActivityChanged(false)
        }
        shelf.destination.onReceive = { [weak self] in
            self?.automaticPresentation = false
            self?.dragActivityChanged(false)
        }
        shelf.onHide = { [weak self] in self?.pendingHide?.cancel(); self?.notch.hide() }
        shelf.onCollapse = { [weak self] in
            self?.automaticPresentation = false
            self?.pendingHide?.cancel()
            self?.notch.hide()
        }
        shelf.onBeginMoving = { [weak self] in
            self?.automaticPresentation = false
            self?.pendingHide?.cancel()
            self?.notch.hide()
        }
        observation.start()
        applySettings()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.resetInteraction() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.applySettings() } })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resetInteraction() }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
                self?.observation.refreshPermission()
                self?.refreshLaunchAtLoginStatus()
            } })
        showSettings()
    }

    func stop() {
        pendingHide?.cancel()
        observation.stop()
        hotKey.stop()
        notch.hide()
        shelf.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    @objc func showShelf() {
        let dragging = NSEvent.pressedMouseButtons & 1 != 0 || observation.isTracking
        activate(dragging ? .hotKey : .manual, point: NSEvent.mouseLocation)
    }

    private func activate(_ reason: ActivationReason, point: CGPoint, screen: NSScreen? = nil) {
        let manual = reason == .manual
        pendingHide?.cancel()
        if !manual, dragActivated, shelf.panel.isVisible { return }
        if !manual { dragActivated = true }
        automaticPresentation = !manual && !shelf.panel.isVisible && store.items.isEmpty
        if reason == .shake || reason == .modifier {
            shelf.recall(near: point)
        } else {
            shelf.show(near: point, focus: manual, notchScreen: screen, expand: manual || reason == .hotKey)
        }
        notch.suppressOccupiedScreens()
        Logger.activation.debug("Shelf presented; manual=\(manual)")
    }

    private func dragActivityChanged(_ active: Bool) {
        pendingHide?.cancel()
        if active {
            dragActivated = false
            notch.setActive(true)
        } else {
            // Mouse-up can precede performDragOperation. Keep all targets alive through that callback.
            pendingHide = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self else { return }
                self.notch.hide()
                self.dragActivated = false
                if self.automaticPresentation, self.store.items.isEmpty, !self.shelf.destination.isReceiving {
                    self.shelf.hide()
                }
            }
        }
    }

    private func applySettings() {
        if L10n.configure(settings.language) { store.notice = nil }
        refreshLaunchAtLoginStatus()
        installMenus()
        updates.setAutomaticChecksEnabled(settings.automaticUpdateChecksEnabled)
        settingsWindow?.title = L10n.text("Layby 设置")
        shelf.panel.title = L10n.text("Layby 文件停放区")
        let status = hotKey.register(settings.hotKeyEnabled ? settings.shortcut : nil)
        hotKeyMessage = status == 0 ? nil : L10n.format("快捷键无法注册（%d），请更换组合键。", status)
        if observation.isTracking { notch.setActive(true) }
    }

    func changeShortcut(_ shortcut: HotKeyShortcut) {
        if !settings.hotKeyEnabled { settings.shortcut = shortcut; return }
        let status = hotKey.register(shortcut)
        guard status == 0 else { hotKeyMessage = L10n.format("该组合键不可用（%d），已保留原快捷键。", status); return }
        settings.shortcut = shortcut
        hotKeyMessage = nil
    }

    func refreshObservation() {
        observation.stop()
        observation.start()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLogin.setEnabled(enabled)
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = L10n.format("无法更新开机自启动设置：%@", error.localizedDescription)
        }
    }

    func refreshLaunchAtLoginStatus() {
        switch launchAtLogin.status {
        case .disabled:
            launchAtLoginEnabled = false
            launchAtLoginNeedsApproval = false
            launchAtLoginMessage = nil
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginNeedsApproval = false
            launchAtLoginMessage = nil
        case .requiresApproval:
            launchAtLoginEnabled = true
            launchAtLoginNeedsApproval = true
            launchAtLoginMessage = L10n.text("需要在系统设置的“登录项与扩展”中允许 Layby。")
        case .unavailable:
            launchAtLoginEnabled = false
            launchAtLoginNeedsApproval = false
            launchAtLoginMessage = L10n.text("当前无法配置开机自启动。")
        }
    }

    func openLoginItemsSettings() {
        launchAtLogin.openSystemSettings()
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(AppInfo.repositoryURL)
    }

    @objc func checkForUpdates() {
        updates.checkForUpdates()
    }

    @objc func showSettings() {
        // Settings are a normal foreground window. This gives Layby ownership of the
        // system menu bar, so opening its status-item menu does not resign the window.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L10n.text("Layby 设置")
            window.titleVisibility = .hidden
            window.contentMinSize = CGSize(width: 700, height: 520)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, coordinator: self))
            window.center()
            settingsWindow = window
        }
        observation.refreshPermission()
        refreshLaunchAtLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the shelf-only app out of the Dock once its foreground window closes.
        if NSApp.activationPolicy() == .regular { NSApp.setActivationPolicy(.accessory) }
    }

    private func resetInteraction() {
        observation.reset()
        pendingHide?.cancel()
        notch.hide()
        dragActivated = false
        if shelf.panel.isVisible {
            shelf.show(near: NSEvent.mouseLocation, focus: false, expand: false)
        }
    }

    private func installMenus() {
        let menu = NSMenu()
        let newShelf = menu.addItem(withTitle: L10n.text("新建停放区"), action: #selector(showShelf), keyEquivalent: "")
        newShelf.image = NSImage(systemSymbolName: "plus.rectangle.on.folder", accessibilityDescription: nil)
        menu.addItem(.separator())
        let preferences = menu.addItem(withTitle: L10n.text("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        preferences.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let checkForUpdates = menu.addItem(withTitle: L10n.text("检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
        checkForUpdates.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        let support = menu.addItem(withTitle: L10n.text("给 Layby 一颗 Star"), action: #selector(openRepository), keyEquivalent: "")
        support.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L10n.text("退出 Layby"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = item == quit ? NSApp : self }
        if settings.menuBarEnabled {
            let statusItem = self.statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let accessibilityDescription = L10n.text("Layby 文件停放区")
            let menuBarIcon = (NSImage(named: "MenuBarIcon")?.copy() as? NSImage)
                ?? Self.drawMenuBarIcon()
            menuBarIcon.isTemplate = true
            menuBarIcon.size = NSSize(width: 18, height: 18)
            menuBarIcon.accessibilityDescription = accessibilityDescription
            statusItem.button?.image = menuBarIcon
            statusItem.button?.toolTip = L10n.text("Layby — 临时文件停放区")
            statusItem.menu = menu
            self.statusItem = statusItem
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        let main = NSMenu()
        let applicationItem = main.addItem(withTitle: "Layby", action: nil, keyEquivalent: "")
        applicationItem.submenu = menu.copy() as? NSMenu
        let editItem = main.addItem(withTitle: L10n.text("编辑"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: L10n.text("编辑"))
        edit.addItem(withTitle: L10n.text("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.text("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.text("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.text("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
        if let applicationMenu = applicationItem.submenu { ShelfServicesController.installMenu(in: applicationMenu) }
    }

    private static func drawMenuBarIcon() -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.25
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // 文件主体与折角。
            path.move(to: NSPoint(x: 5.25, y: 7.3))
            path.line(to: NSPoint(x: 5.25, y: 2.9))
            path.curve(to: NSPoint(x: 6.6, y: 1.55),
                       controlPoint1: NSPoint(x: 5.25, y: 2.15),
                       controlPoint2: NSPoint(x: 5.85, y: 1.55))
            path.line(to: NSPoint(x: 10.7, y: 1.55))
            path.line(to: NSPoint(x: 13.95, y: 4.8))
            path.line(to: NSPoint(x: 13.95, y: 7.3))
            path.move(to: NSPoint(x: 10.7, y: 1.55))
            path.line(to: NSPoint(x: 10.7, y: 3.8))
            path.curve(to: NSPoint(x: 11.7, y: 4.8),
                       controlPoint1: NSPoint(x: 10.7, y: 4.35),
                       controlPoint2: NSPoint(x: 11.15, y: 4.8))
            path.line(to: NSPoint(x: 13.95, y: 4.8))

            // 后托盘只露出文件两侧的边缘。
            path.move(to: NSPoint(x: 2.25, y: 8.65))
            path.line(to: NSPoint(x: 2.25, y: 8.05))
            path.curve(to: NSPoint(x: 3.85, y: 6.45),
                       controlPoint1: NSPoint(x: 2.25, y: 7.15),
                       controlPoint2: NSPoint(x: 2.95, y: 6.45))
            path.line(to: NSPoint(x: 5.25, y: 6.45))
            path.move(to: NSPoint(x: 13.95, y: 6.45))
            path.line(to: NSPoint(x: 14.15, y: 6.45))
            path.curve(to: NSPoint(x: 15.75, y: 8.05),
                       controlPoint1: NSPoint(x: 15.05, y: 6.45),
                       controlPoint2: NSPoint(x: 15.75, y: 7.15))
            path.line(to: NSPoint(x: 15.75, y: 8.65))

            // 前托盘的凹口对应应用图标中承托文件的位置。
            path.move(to: NSPoint(x: 2.25, y: 8.7))
            path.curve(to: NSPoint(x: 3.7, y: 7.25),
                       controlPoint1: NSPoint(x: 2.25, y: 7.9),
                       controlPoint2: NSPoint(x: 2.9, y: 7.25))
            path.line(to: NSPoint(x: 5.25, y: 7.25))
            path.curve(to: NSPoint(x: 6.48, y: 7.92),
                       controlPoint1: NSPoint(x: 5.75, y: 7.25),
                       controlPoint2: NSPoint(x: 6.2, y: 7.5))
            path.line(to: NSPoint(x: 7.38, y: 9.27))
            path.curve(to: NSPoint(x: 9.02, y: 10.15),
                       controlPoint1: NSPoint(x: 7.75, y: 9.82),
                       controlPoint2: NSPoint(x: 8.36, y: 10.15))
            path.curve(to: NSPoint(x: 10.66, y: 9.27),
                       controlPoint1: NSPoint(x: 9.68, y: 10.15),
                       controlPoint2: NSPoint(x: 10.29, y: 9.82))
            path.line(to: NSPoint(x: 11.56, y: 7.92))
            path.curve(to: NSPoint(x: 12.79, y: 7.25),
                       controlPoint1: NSPoint(x: 11.84, y: 7.5),
                       controlPoint2: NSPoint(x: 12.29, y: 7.25))
            path.line(to: NSPoint(x: 14.3, y: 7.25))
            path.curve(to: NSPoint(x: 15.75, y: 8.7),
                       controlPoint1: NSPoint(x: 15.1, y: 7.25),
                       controlPoint2: NSPoint(x: 15.75, y: 7.9))
            path.line(to: NSPoint(x: 15.75, y: 13.75))
            path.curve(to: NSPoint(x: 13.05, y: 16.45),
                       controlPoint1: NSPoint(x: 15.75, y: 15.25),
                       controlPoint2: NSPoint(x: 14.55, y: 16.45))
            path.line(to: NSPoint(x: 4.95, y: 16.45))
            path.curve(to: NSPoint(x: 2.25, y: 13.75),
                       controlPoint1: NSPoint(x: 3.45, y: 16.45),
                       controlPoint2: NSPoint(x: 2.25, y: 15.25))
            path.close()
            path.stroke()
            return true
        }
    }
}
