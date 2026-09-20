import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Identifies native file hit areas even though their SwiftUI content is generic.
@MainActor protocol ShelfFileSelectionTarget: AnyObject {}

struct DraggableFileView<Content: View>: NSViewRepresentable {
    let store: ShelfStore
    let scope: ShelfDragScope
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> FileDragView<Content> {
        FileDragView(store: store, scope: scope, content: content())
    }
    func updateNSView(_ view: FileDragView<Content>, context: Context) {
        view.host.rootView = content()
        view.scope = scope
    }
}

@MainActor
final class FileDragView<Content: View>: NSView, NSDraggingSource, ShelfFileSelectionTarget {
    let host: NSHostingView<Content>
    let store: ShelfStore
    var scope: ShelfDragScope
    private var itemID: UUID? { if case .item(let id) = scope { return id }; return nil }
    private var mouseDownEvent: NSEvent?
    private var activeItems: [ShelfItem] = []
    private var hasStarted = false

    init(store: ShelfStore, scope: ShelfDragScope, content: Content) {
        self.store = store
        self.scope = scope
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
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        mouseDownEvent = event
        hasStarted = false
        window?.makeFirstResponder(self)
        if let itemID {
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
        activeItems = entries
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
        if !hasStarted, let itemID, modifiers.intersection([.command, .shift]).isEmpty {
            if event.clickCount == 2 {
                store.openFolder(itemID)
                return
            }
            store.select(itemID, extending: false)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.isDraggingOut = false
        activeItems.removeAll()
        mouseDownEvent = nil
        // An unsuccessful destination never removes the user's references.
    }
    override func accessibilityPerformPress() -> Bool {
        guard let itemID else { return false }
        store.select(itemID, extending: false)
        return true
    }
}
