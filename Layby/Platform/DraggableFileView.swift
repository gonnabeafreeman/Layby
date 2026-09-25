import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Identifies native file hit areas even though their SwiftUI content is generic.
@MainActor protocol ShelfFileSelectionTarget: AnyObject {}

struct DraggableFileView<Content: View>: NSViewRepresentable {
    let store: ShelfStore
    let scope: ShelfDragScope
    let settings: AppSettings
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> FileDragView<Content> {
        FileDragView(store: store, scope: scope, settings: settings, content: content())
    }
    func updateNSView(_ view: FileDragView<Content>, context: Context) {
        view.host.rootView = content()
        view.scope = scope
        view.settings = settings
    }
}

@MainActor
final class FileDragView<Content: View>: NSView, NSDraggingSource, ShelfFileSelectionTarget {
    let host: NSHostingView<Content>
    let store: ShelfStore
    var scope: ShelfDragScope
    var settings: AppSettings
    private var itemID: UUID? { if case .item(let id) = scope { return id }; return nil }
    private var mouseDownEvent: NSEvent?
    private var activeItems: [ShelfItem] = []
    private var hasStarted = false
    private var deferredSelection = false
    private var movingOriginals = false

    init(store: ShelfStore, scope: ShelfDragScope, settings: AppSettings? = nil, content: Content) {
        self.store = store
        self.scope = scope
        self.settings = settings ?? AppSettings()
        host = NSHostingView(rootView: content)
        host.sizingOptions = []
        super.init(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.focusRingType = .none
        focusRingType = .none
        addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if let panel = window as? ShelfPanel,
           panel.handleQuickLookKey(event) || panel.handleNavigationKey(event) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = itemID, let panel = window as? ShelfPanel else { return super.menu(for: event) }
        panel.makeFirstResponder(self)
        if panel.hasPendingInteractionFocus {
            panel.performAfterInteractionFocus { [weak self, weak panel] in
                guard let self, let panel, self.window === panel,
                      let menu = panel.services?.contextMenu(for: id, preview: { [weak panel] id in
                          panel?.quickLook?.preview(id)
                      }) else { return }
                // By the time activation completes, the physical click has already
                // ended. popUpContextMenu replays the captured mouseDown event, unlike
                // popUp(positioning:at:in:), which starts a fresh tracking session that
                // sees no button down and dismisses the menu the instant it appears.
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return nil
        }
        panel.makeKey()
        return panel.services?.contextMenu(for: id) { [weak panel] id in panel?.quickLook?.preview(id) }
    }

    override func mouseDown(with event: NSEvent) {
        let moveRequested = settings.moveShortcut.matches(event.modifierFlags)
        if event.modifierFlags.contains(.control) && !moveRequested {
            rightMouseDown(with: event)
            return
        }
        mouseDownEvent = event
        hasStarted = false
        movingOriginals = false
        // A Command-click still changes selection on mouse-up. Deferring it
        // lets a Command-drag preserve an existing multi-selection for moving.
        deferredSelection = moveRequested
        window?.makeFirstResponder(self)
        if let itemID, !deferredSelection {
            if event.modifierFlags.contains(.shift) {
                store.select(itemID, extending: event.modifierFlags.contains(.command), range: true)
            }
            else if event.modifierFlags.contains(.command) { store.select(itemID, extending: true) }
            else if !store.selection.contains(itemID) { store.select(itemID, extending: false) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasStarted, let initial = mouseDownEvent,
              hypot(event.locationInWindow.x - initial.locationInWindow.x,
                    event.locationInWindow.y - initial.locationInWindow.y) >= 4 else { return }
        // Sorted by name so multiple files land pre-arranged (rather than piled on
        // one point) when dropped into a Finder icon view, without touching the
        // user's Finder sort preference.
        let entries = store.dragItems(for: scope).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !entries.isEmpty else { return }
        let moveRequested = settings.moveShortcut.matches(event.modifierFlags)
        if moveRequested && entries.contains(where: \.isManaged) {
            store.notice = L10n.text("来源应用生成的临时文件不能移动原件；松开移动键后可复制拖出。")
            return
        }
        if deferredSelection, let itemID, !store.selection.contains(itemID) {
            store.select(itemID, extending: false)
        }
        activeItems = entries
        movingOriginals = moveRequested
        let origin = convert(event.locationInWindow, from: nil)
        let columns = max(1, Int(ceil(sqrt(Double(entries.count)))))
        let spacing: CGFloat = 72
        let draggingItems = entries.enumerated().compactMap { index, entry -> NSDraggingItem? in
            guard let url = entry.url, let lease = entry.lease else { return nil }
            let writer: NSPasteboardWriting
            if entry.isManaged {
                let delegate = FilePromiseExport(lease: lease, queue: store.managedFiles.queue)
                let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: url.pathExtension) ?? .data)
                let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
                provider.userInfo = delegate
                writer = provider
            } else { writer = url as NSURL }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let row = index / columns
            let col = index % columns
            let x = origin.x - 20 + CGFloat(col) * spacing
            let y = origin.y - 20 - CGFloat(row) * spacing
            item.setDraggingFrame(CGRect(x: x, y: y, width: 40, height: 40), contents: entry.icon)
            return item
        }
        guard !draggingItems.isEmpty else { return }
        if movingOriginals && draggingItems.count != entries.count {
            activeItems.removeAll()
            movingOriginals = false
            store.notice = L10n.text("部分文件无法提供给目标，移动已取消。")
            return
        }
        hasStarted = true
        store.isDraggingOut = true
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        // Use the modifiers at mouse-down: releasing Shift before the mouse must
        // not collapse the range we just selected.
        let modifiers = mouseDownEvent?.modifierFlags ?? event.modifierFlags
        mouseDownEvent = nil
        if !hasStarted, deferredSelection, let itemID {
            if modifiers.contains(.shift) {
                store.select(itemID, extending: modifiers.contains(.command), range: true)
            } else if modifiers.contains(.command) {
                store.select(itemID, extending: true)
            } else {
                store.select(itemID, extending: false)
            }
        }
        deferredSelection = false
        if !hasStarted, let itemID, modifiers.intersection([.command, .shift]).isEmpty {
            if event.clickCount == 2 {
                store.openFolder(itemID)
                return
            }
            store.select(itemID, extending: false)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? (movingOriginals ? .move : .copy) : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { movingOriginals }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.isDraggingOut = false
        if movingOriginals { store.reconcileMovedDrag(activeItems, operation: operation) }
        activeItems.removeAll()
        mouseDownEvent = nil
        deferredSelection = false
        movingOriginals = false
    }
    override func accessibilityPerformPress() -> Bool {
        guard let itemID else { return false }
        store.select(itemID, extending: false)
        return true
    }
}
