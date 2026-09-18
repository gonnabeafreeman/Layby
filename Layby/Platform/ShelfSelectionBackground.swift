import AppKit
import SwiftUI

struct ShelfSelectionBackground: NSViewRepresentable {
    let store: ShelfStore

    func makeNSView(context: Context) -> ShelfSelectionBackgroundView {
        ShelfSelectionBackgroundView(store: store)
    }

    func updateNSView(_ view: ShelfSelectionBackgroundView, context: Context) {}
}

/// Tracks the browser viewport and its padding without intercepting scrolling,
/// file dragging or SwiftUI buttons. The window dispatches mouse-down here first.
@MainActor final class ShelfSelectionBackgroundView: NSView {
    private let store: ShelfStore

    init(store: ShelfStore) {
        self.store = store
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let panel = window as? ShelfPanel, panel.selectionBackground === self {
            panel.selectionBackground = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? ShelfPanel)?.selectionBackground = self
    }

    func handleMouseDown(_ event: NSEvent) {
        guard !store.selection.isEmpty, isBlankArea(event) else { return }
        store.clearSelection()
        window?.makeFirstResponder(nil)
    }

    /// Returns true when the event belongs to empty list/grid space and has
    /// therefore been consumed by the shelf's background context menu.
    func handleContextMenu(_ event: NSEvent) -> Bool {
        guard isBlankArea(event), let panel = window as? ShelfPanel else { return false }
        let point = convert(event.locationInWindow, from: nil)
        panel.performAfterInteractionFocus { [weak self, weak panel] in
            guard let self, let panel, self.window === panel,
                  let menu = panel.services?.backgroundContextMenu() else { return }
            menu.popUp(positioning: nil, at: point, in: self)
        }
        return true
    }

    private func isBlankArea(_ event: NSEvent) -> Bool {
        guard store.presentation.isExpanded, !isHiddenOrHasHiddenAncestor,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let root = window?.contentView else { return false }
        var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
        while let view = hit {
            if let destination = view as? DropDestinationView, destination.blocksInteraction { return false }
            if view is ShelfFileSelectionTarget || view is NSControl || view is HeaderDragView { return false }
            hit = view.superview
        }
        return true
    }
}
