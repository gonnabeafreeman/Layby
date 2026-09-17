import AppKit
import Quartz

/// Keep both security-scoped access and promised-file storage alive for Quick Look.
final class ShelfPreviewItem: NSObject, QLPreviewItem {
    let id: UUID
    private let lease: FileAccessLease
    let previewItemTitle: String?
    var previewItemURL: URL? { lease.url }

    init?(_ item: ShelfItem) {
        guard item.state.isReady, let lease = item.lease, item.url != nil else { return nil }
        id = item.id
        self.lease = lease
        previewItemTitle = item.name
        super.init()
    }
}

@MainActor
final class ShelfQuickLookController: NSObject, @MainActor QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let store: ShelfStore
    private weak var shelfPanel: ShelfPanel?
    private weak var controlledPanel: QLPreviewPanel?
    private var items: [ShelfPreviewItem] = []
    private var keyMonitor: Any?
    private var previewsAllItems = false
    var hasItems: Bool { !items.isEmpty }

    init(store: ShelfStore, shelfPanel: ShelfPanel) {
        self.store = store
        self.shelfPanel = shelfPanel
        super.init()
        store.onPreviewChange = { [weak self] in self?.selectionDidChange() }
    }

    static func isToggleKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 49 &&
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    @discardableResult func toggle() -> Bool {
        if dismiss() { return true }
        previewsAllItems = false
        return show(store.previewItems.compactMap(ShelfPreviewItem.init))
    }

    func preview(_ id: UUID) {
        guard store.presentation.isExpanded, store.visibleReadyItems.contains(where: { $0.id == id }) else { return }
        store.select(id, extending: false)
        previewsAllItems = false
        _ = show(store.previewItems.compactMap(ShelfPreviewItem.init))
    }

    /// Quick Look every item currently held, regardless of selection. Used by
    /// the stack's quick-actions menu, where individual items are not selectable.
    @discardableResult func previewAll() -> Bool {
        if dismiss() { return true }
        previewsAllItems = true
        return show(store.items.compactMap(ShelfPreviewItem.init))
    }

    private func show(_ candidates: [ShelfPreviewItem]) -> Bool {
        guard !candidates.isEmpty, let shelfPanel else { return false }
        items = candidates
        // The shelf is a nonactivating utility window; make it the key responder
        // before asking the shared panel to find its controller.
        NSApp.activate(ignoringOtherApps: true)
        shelfPanel.makeKey()
        guard let panel = QLPreviewPanel.shared() else { items.removeAll(); return false }
        // A hidden QLPreviewPanel has not entered its responder-chain control
        // lifecycle yet. Present it before checking for beginControl; otherwise
        // the very first Space press exits before the panel can acquire a source.
        panel.makeKeyAndOrderFront(nil)
        panel.updateController()
        guard controlledPanel === panel else { items.removeAll(); return false }
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        installKeyMonitor()
        return true
    }

    // Called exclusively by ShelfPanel's native responder-chain control hooks.
    func beginControl(_ panel: QLPreviewPanel) {
        controlledPanel = panel
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    func endControl(_ panel: QLPreviewPanel) {
        guard controlledPanel === panel else { return }
        panel.dataSource = nil
        panel.delegate = nil
        controlledPanel = nil
        finishSession()
    }

    @discardableResult func dismiss() -> Bool {
        guard hasItems else { return false }
        controlledPanel?.close()
        finishSession()
        releaseEmptyPanel()
        return true
    }

    func stop() {
        dismiss()
        // QLPreviewPanel's delegate/dataSource are unowned; detach before the
        // shelf owner can be destroyed, even if the panel is already hidden.
        if let panel = controlledPanel {
            panel.dataSource = nil
            panel.delegate = nil
            controlledPanel = nil
        }
        finishSession()
        store.onPreviewChange = nil
    }

    private func releaseEmptyPanel() {
        guard !hasItems, let panel = controlledPanel else { return }
        panel.reloadData()
        panel.updateController()
    }

    private func finishSession() {
        items.removeAll()
        previewsAllItems = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func selectionDidChange() {
        guard hasItems else { return }
        let candidates = (previewsAllItems ? store.items : store.previewItems).compactMap(ShelfPreviewItem.init)
        guard !candidates.isEmpty else { dismiss(); return }
        guard let panel = controlledPanel else { return }
        let currentID = (panel.currentPreviewItem as? ShelfPreviewItem)?.id
        items = candidates
        panel.reloadData()
        panel.currentPreviewItemIndex = items.firstIndex { $0.id == currentID } ?? 0
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Handle Space before movie/PDF responders consume it, and keep Escape
        // inside Quick Look instead of forwarding it to the shelf's clear action.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.hasItems, let panel = self.controlledPanel,
                      event.window === panel || event.window === self.shelfPanel else { return false }
                if Self.isToggleKey(event) || event.keyCode == 53 {
                    if !event.isARepeat { self.dismiss() }
                    return true
                }
                // Quick Look's movie/PDF responders otherwise use arrows for
                // playback or page navigation. Single selection navigates files.
                if let direction = ShelfPanel.navigationDirection(for: event) {
                    return self.store.moveSelection(direction, skippingUnavailable: true)
                }
                return false
            }
            return handled ? nil : event
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items.indices.contains(index) ? items[index] : nil
    }

    func windowWillClose(_ notification: Notification) {
        finishSession()
        // Let AppKit finish closing before refreshing the responder chain.
        // Also release Quick Look's cached item after a native close-button action.
        Task { @MainActor [weak self] in self?.releaseEmptyPanel() }
    }
}
