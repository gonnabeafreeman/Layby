import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Supplies the shelf's current files to the system-managed Services menu.
@MainActor
final class ShelfServicesController: NSObject, @MainActor NSServicesMenuRequestor {
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let pathAliases = [NSPasteboard.PasteboardType("NSStringPboardType"), .init("NSPasteboardTypeString")]
    static let sendTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, filenamesType, .string] + pathAliases
    private let catalog: FileServiceCatalog
    private let sharingServices: ([URL]) -> [NSSharingService]
    private let applicationsForURL: (URL) -> [URL]
    private let defaultApplicationForURL: (URL) -> URL?
    private let performService: (String, NSPasteboard) -> Bool
    private let store: ShelfStore
    private weak var pendingServicesView: NSView?
    private var pendingServicesRequest: UUID?
    private var trackingServicesMenu: NSMenu?
    // Providers may open a URL asynchronously after the service has returned.
    // Keep access and managed files alive until this app session ends, even if
    // the user closes/clears the shelf in the meantime.
    private var sentLeases: [ObjectIdentifier: FileAccessLease] = [:]

    init(store: ShelfStore, catalog: FileServiceCatalog? = nil,
         sharingServices: @escaping ([URL]) -> [NSSharingService] = { NSSharingService.sharingServices(forItems: $0) },
         applicationsForURL: @escaping (URL) -> [URL] = { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
         defaultApplicationForURL: @escaping (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
         performService: @escaping (String, NSPasteboard) -> Bool = { NSPerformService($0, $1) }) {
        self.store = store
        self.catalog = catalog ?? .shared
        self.sharingServices = sharingServices
        self.applicationsForURL = applicationsForURL
        self.defaultApplicationForURL = defaultApplicationForURL
        self.performService = performService
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(cancelServicesMenu),
            name: NSApplication.didResignActiveNotification, object: NSApp)
    }

    static func installMenu(in applicationMenu: NSMenu) {
        NSApp.registerServicesMenuSendTypes(sendTypes, returnTypes: [])
        let menu = NSMenu(title: L10n.text("服务"))
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        applicationMenu.insertItem(item, at: max(0, applicationMenu.numberOfItems - 2))
        NSApp.servicesMenu = menu
    }

    var items: [ShelfItem] {
        let candidates = store.presentation == .stack ? store.items
            : store.visibleItems.filter { store.selection.contains($0.id) }
        guard !candidates.isEmpty,
              candidates.allSatisfy({ $0.state.isReady && $0.url?.isFileURL == true && $0.lease != nil }) else { return [] }
        return candidates
    }

    func accepts(sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Bool {
        guard let sendType, Self.sendTypes.contains(sendType), returnType == nil else { return false }
        return !items.isEmpty
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        writeFiles(items, to: pasteboard, types: types)
    }

    private func writeFiles(_ selected: [ShelfItem], to pasteboard: NSPasteboard,
                            types: [NSPasteboard.PasteboardType]) -> Bool {
        guard !selected.isEmpty, types.contains(where: Self.sendTypes.contains) else { return false }
        let urls = selected.compactMap(\.url)
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            store.notice = "文件不可用，请重新检查后再使用服务"
            return false
        }
        pasteboard.clearContents()
        var written = false
        if types.contains(.fileURL) || types.contains(.URL) { written = pasteboard.writeObjects(urls as [NSURL]) }
        // File services such as Parallels request paths under string aliases,
        // while Dropover reads URL objects. Keep all URLs for multi-file input.
        let paths = urls.map(\.path).joined(separator: "\n")
        for type in [.string] + Self.pathAliases where types.contains(type) {
            pasteboard.addTypes([type], owner: nil)
            written = pasteboard.setString(paths, forType: type) || written
        }
        if types.contains(Self.filenamesType) {
            pasteboard.addTypes([Self.filenamesType], owner: nil)
            written = pasteboard.setPropertyList(urls.map(\.path), forType: Self.filenamesType) || written
        }
        if written {
            for item in selected {
                if let lease = item.lease { sentLeases[ObjectIdentifier(lease)] = lease }
            }
        }
        return written
    }

    func stop() {
        cancelServicesMenu()
        sentLeases.removeAll()
    }

    func prepareContext(for id: UUID) {
        // Right-clicking one of the selected files preserves the entire group.
        if !store.selection.contains(id) { store.select(id, extending: false) }
    }

    func contextMenu(for id: UUID, preview: @escaping (UUID) -> Void) -> NSMenu? {
        guard let item = store.visibleItems.first(where: { $0.id == id }) else { return nil }
        prepareContext(for: id)
        let menu = NSMenu()
        // Lead with the same quick actions as the stack button, instead of
        // AppKit appending generic text/selection services to this menu.
        menu.allowsContextMenuPlugIns = false
        menu.automaticallyInsertsWritingToolsItems = false
        appendQuickActionGroups(to: menu, quickLookEnabled: item.state.isReady, quickLookAction: { preview(id) })
        appendShelfManagementActions(to: menu, item: item, id: id)
        menu.addItem(.separator())
        let serviceItem = menu.addItem(withTitle: L10n.text("服务"), action: nil, keyEquivalent: "")
        serviceItem.submenu = fileServicesMenu()
        return menu
    }

    /// File-specific management remains available from the context menu, but is
    /// separate from the external Services catalog.
    private func appendShelfManagementActions(to menu: NSMenu, item: ShelfItem, id: UUID) {
        if item.isDirectory {
            menu.addItem(ShelfMenuAction("打开文件夹", enabled: item.state.isReady) { [store] in store.openFolder(id) })
        }
        if item.url != nil {
            menu.addItem(ShelfMenuAction("重新检查") { [store] in store.retry(id) })
        }
        if !store.isBrowsingFolder {
            menu.addItem(ShelfMenuAction("从停放区移除") { [store] in store.remove([id]) })
        }
        menu.addItem(ShelfMenuAction("清空停放区") { [store] in store.clear() })
    }

    /// Appends the two shared menu groups: file actions and the services exposed
    /// by the macOS share sheet. Empty groups and unavailable actions are omitted.
    private func appendQuickActionGroups(to menu: NSMenu, quickLookEnabled: Bool,
                                         quickLookAction: @escaping () -> Void) {
        let groups = quickActionGroups(quickLookEnabled: quickLookEnabled, quickLookAction: quickLookAction)
        for (index, group) in groups.enumerated() where !group.isEmpty {
            if index > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
        if !groups.allSatisfy(\.isEmpty) { menu.addItem(.separator()) }
    }

    /// The first group contains local file actions. The second mirrors every
    /// currently usable service from the macOS share sheet.
    private func quickActionGroups(quickLookEnabled: Bool,
                                   quickLookAction: @escaping () -> Void) -> [[NSMenuItem]] {
        let selection = items
        let urls = sharingURLs(for: selection)

        let finder = ShelfMenuAction("在 Finder 中显示", enabled: urls != nil) {
            if let urls { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        // Prefer Finder's real app icon, matching the Finder command itself.
        // The symbol only covers unusual environments where Finder is unavailable.
        finder.image = Self.menuIcon(Self.finderIcon) ?? Self.menuSymbol("folder")
        Self.showMenuImage(finder)

        let quickLook = ShelfMenuAction("快速查看", enabled: quickLookEnabled, action: quickLookAction)
        quickLook.image = Self.menuSymbol("eye")
        Self.showMenuImage(quickLook)

        var fileActions: [NSMenuItem] = []
        if let openWith = openWithMenuItem(for: urls) { fileActions.append(openWith) }
        fileActions.append(contentsOf: [finder, quickLook])

        let shareActions: [NSMenuItem]
        if let urls {
            shareActions = sharingServices(urls).compactMap { service in
                guard service.canPerform(withItems: urls) else { return nil }
                let action = ShelfMenuAction(service.title) { [weak self] in self?.perform(service, urls: urls) }
                action.image = Self.menuIcon(service.image)
                Self.showMenuImage(action)
                return action
            }
        } else {
            shareActions = []
        }
        return [fileActions, shareActions]
    }

    private func sharingURLs(for selection: [ShelfItem]) -> [URL]? {
        guard !selection.isEmpty, selection.allSatisfy({ $0.state.isReady && $0.url != nil }) else { return nil }
        let urls = selection.compactMap(\.url)
        return urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) ? urls : nil
    }

    private func perform(_ service: NSSharingService?, urls: [URL]?) {
        guard let urls, let service, service.canPerform(withItems: urls) else {
            store.notice = "当前无法使用该功能"
            return
        }
        service.perform(withItems: urls)
    }

    /// "Open With…" mirrors Finder: a submenu of every capable application
    /// (default first) plus "Other…". The command is omitted when no application
    /// supports every selected file and carries the first application's icon.
    private func openWithMenuItem(for urls: [URL]?) -> NSMenuItem? {
        guard let urls, !urls.isEmpty else { return nil }
        let applications = openWithApplications(for: urls)
        guard let firstApplication = applications.first else { return nil }
        let item = NSMenuItem(title: L10n.text("用…打开"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.allowsContextMenuPlugIns = false
        for app in applications {
            let action = ShelfMenuAction(FileManager.default.displayName(atPath: app.path)) {
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            action.image = Self.menuIcon(NSWorkspace.shared.icon(forFile: app.path))
            Self.showMenuImage(action)
            submenu.addItem(action)
        }
        submenu.addItem(.separator())
        submenu.addItem(ShelfMenuAction("其他…") { [weak self] in self?.chooseOtherApplication(for: urls) })
        item.image = Self.menuIcon(NSWorkspace.shared.icon(forFile: firstApplication.path))
        Self.showMenuImage(item)
        item.submenu = submenu
        return item
    }

    /// Applications capable of opening every selected file, default application first.
    private func openWithApplications(for urls: [URL]) -> [URL] {
        guard let first = urls.first else { return [] }
        var candidates = Set(applicationsForURL(first).map(\.standardizedFileURL))
        for url in urls.dropFirst() where !candidates.isEmpty {
            candidates.formIntersection(Set(applicationsForURL(url).map(\.standardizedFileURL)))
        }
        let defaultApp = defaultApplicationForURL(first)?.standardizedFileURL
        return candidates.sorted { a, b in
            if a == defaultApp { return true }
            if b == defaultApp { return false }
            return FileManager.default.displayName(atPath: a.path).localizedStandardCompare(FileManager.default.displayName(atPath: b.path)) == .orderedAscending
        }
    }

    private func chooseOtherApplication(for urls: [URL]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.text("打开")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private static let finderIcon: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    private static func menuIcon(_ image: NSImage?) -> NSImage? {
        guard let image, let icon = image.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private static func menuSymbol(_ name: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return menuIcon(symbol)
    }

    /// macOS 27 defaults menu-item images to automatic visibility, which normally
    /// hides them. These file actions intentionally use their leading icons.
    private static func showMenuImage(_ item: NSMenuItem) {
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }

    /// Quick actions plus the "Services" category, used by the stack's dropdown button.
    func quickActionsMenu(quickLookEnabled: Bool, quickLookAction: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        appendQuickActionGroups(to: menu, quickLookEnabled: quickLookEnabled, quickLookAction: quickLookAction)
        let serviceItem = menu.addItem(withTitle: L10n.text("服务"), action: nil, keyEquivalent: "")
        serviceItem.submenu = fileServicesMenu()
        return menu
    }

    func showAllServices(from view: NSView) {
        guard pendingServicesRequest == nil, trackingServicesMenu == nil,
              canShowAllServices(from: view) else { return }
        let request = UUID()
        pendingServicesRequest = request
        pendingServicesView = view
        // Activation is asynchronous. Starting menu tracking before it finishes
        // makes AppKit dismiss the menu during the foreground transition.
        if NSApp.isActive {
            applicationDidBecomeActive()
        } else {
            NSApp.activate()
        }
        // Activation can be refused. Never reopen a stale click much later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard self?.pendingServicesRequest == request else { return }
            self?.cancelServicesMenu()
        }
    }

    @objc private func applicationDidBecomeActive() {
        guard NSApp.isActive, let request = pendingServicesRequest else { return }
        guard let view = pendingServicesView, canShowAllServices(from: view),
              let window = view.window else {
            cancelServicesMenu()
            return
        }
        window.makeKey()
        window.makeFirstResponder(view)
        // Finish activation and the current click before entering NSMenu's
        // nested tracking loop.
        DispatchQueue.main.async { [weak self, weak view, weak window] in
            guard let self, self.pendingServicesRequest == request else { return }
            self.pendingServicesRequest = nil
            self.pendingServicesView = nil
            guard NSApp.isActive, let view, let window, view.window === window,
                  window.isKeyWindow, self.canShowAllServices(from: view) else { return }
            let quickLook = (window as? ShelfPanel)?.quickLook
            let menu = self.quickActionsMenu(quickLookEnabled: !self.items.isEmpty) { _ = quickLook?.previewAll() }
            self.trackingServicesMenu = menu
            defer { self.trackingServicesMenu = nil }
            let point = CGPoint(x: 0, y: view.isFlipped ? view.bounds.maxY : view.bounds.minY)
            menu.popUp(positioning: nil, at: point, in: view)
        }
    }

    private func canShowAllServices(from view: NSView) -> Bool {
        !items.isEmpty && store.presentation == .stack && !view.isHiddenOrHasHiddenAncestor
            && view.window?.isVisible == true
            && (view.window as? ShelfPanel)?.permitsFileServices == true
    }

    @objc func cancelServicesMenu() {
        pendingServicesRequest = nil
        pendingServicesView = nil
        trackingServicesMenu?.cancelTracking()
    }

    func fileServicesMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.text("服务"))
        menu.allowsContextMenuPlugIns = false
        appendCatalogServices(to: menu)
        return menu
    }

    /// Appends the dynamic, third-party Services-menu catalog to an existing menu.
    private func appendCatalogServices(to menu: NSMenu) {
        catalog.refreshIfNeeded()
        let selection = items
        let services = catalog.entries.filter { $0.accepts(selection) }
        let names = Dictionary(grouping: services, by: \.title)
        for service in services {
            let duplicate = (names[service.title]?.count ?? 0) > 1
            let title = duplicate ? "\(service.title) (\(service.applicationName))" : service.title
            menu.addItem(ShelfMenuAction(title) { [weak self] in
                self?.invoke(service, selection: selection, invocationName: duplicate ? title : service.invocationName)
            })
        }
        if services.isEmpty {
            menu.addItem(withTitle: L10n.text(catalog.isLoaded ? "没有适用的文件服务" : "正在读取文件服务…"),
                         action: nil, keyEquivalent: "")
        }
    }

    /// Invoke the registered service on a private pasteboard; do not launch an
    /// arbitrary executable or substitute an application's default Open action.
    func invoke(_ service: FileService, selection: [ShelfItem], invocationName: String? = nil) {
        guard !selection.isEmpty, service.accepts(selection),
              selection.allSatisfy({ $0.state.isReady && $0.lease != nil && $0.url != nil }) else { return }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        guard writeFiles(selection, to: board, types: Self.sendTypes) else { return }
        if !performService(invocationName ?? service.invocationName, board) {
            store.notice = L10n.format("无法执行文件服务“%@”，请确认提供该服务的应用可用。", service.title)
        }
    }
}

@MainActor private final class ShelfMenuAction: NSMenuItem, NSMenuItemValidation {
    private let invoke: () -> Void
    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        invoke = action
        super.init(title: L10n.text(title), action: #selector(invokeAction), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invokeAction() { invoke() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled }
}

struct ShelfServicesButton: NSViewRepresentable {
    let enabled: Bool
    func makeNSView(context: Context) -> ShelfServicesButtonView { ShelfServicesButtonView() }
    func updateNSView(_ view: ShelfServicesButtonView, context: Context) { view.setEnabled(enabled) }
}

@MainActor final class ShelfServicesButtonView: NSView {
    private var host: NSHostingView<ServicesButtonContent>!
    init() {
        super.init(frame: .zero)
        host = NSHostingView(rootView: content(enabled: false))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor), host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    func setEnabled(_ enabled: Bool) { host.rootView = content(enabled: enabled) }
    private func content(enabled: Bool) -> ServicesButtonContent {
        ServicesButtonContent(enabled: enabled) { [weak self] in
            guard let self else { return }
            (self.window as? ShelfPanel)?.services?.showAllServices(from: self)
        }
    }
}

private struct ServicesButtonContent: View {
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                .frame(width: ShelfLayout.headerButtonSize, height: ShelfLayout.headerButtonSize)
        }
        .buttonStyle(ShelfSolidButtonStyle())
        .disabled(!enabled)
        .help(L10n.text("对全部文件执行更多操作"))
        .accessibilityLabel(L10n.text("对全部文件执行更多操作"))
    }
}
