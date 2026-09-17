import AppKit
import Testing
@testable import LaybyKit

@MainActor @Suite(.serialized)
struct ShelfDockingTests {
    @Test func externalDisplaysUseTheirOwnTopCenter() {
        // Left, above, and below the primary display, including a portrait display.
        for screen in [CGRect(x: -2560, y: 0, width: 2560, height: 1440),
                       CGRect(x: 200, y: 1080, width: 1920, height: 1080),
                       CGRect(x: 1920, y: -1920, width: 1080, height: 1920)] {
            for menuHeight: CGFloat in [0, 24, 38] {
                let visible = CGRect(x: screen.minX + 80, y: screen.minY,
                    width: screen.width - 80, height: screen.height - menuHeight)
                let target = ShelfDockTarget.target(displayID: 42, frame: screen,
                    visibleFrame: visible, notch: nil)
                for size in [ShelfLayout.windowSize, ShelfLayout.windowSize(for: .grid), ShelfLayout.capsuleWindowSize] {
                    let frame = target.frame(for: size)
                    #expect(frame.midX == screen.midX)
                    let content = frame.insetBy(dx: ShelfLayout.shadowInset, dy: ShelfLayout.shadowInset)
                    #expect(content.maxY == visible.maxY - ShelfDockTarget.gap)
                    #expect(visible.contains(content))
                    #expect(target.captures(frame.offsetBy(dx: 80, dy: -52)))
                    #expect(!target.captures(frame.offsetBy(dx: 81, dy: 0)))
                    #expect(!target.captures(frame.offsetBy(dx: 0, dy: -53)))
                }
            }
        }
    }

    @Test func everyConnectedDisplayProvidesADockTarget() {
        let targets = ShelfDockTarget.currentScreens()
        #expect(targets.count == NSScreen.screens.count)
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            #expect(targets.contains { $0.displayID == id?.uint32Value })
        }
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 8), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func dockingUsesTheSameAnchorForEverySizeAndNegativeScreenOrigins() {
        let target = ShelfDockTarget(displayID: 1,
            anchor: CGRect(x: -900, y: 960, width: 200, height: 40),
            visibleFrame: CGRect(x: -1600, y: 0, width: 1600, height: 960))
        for size in [ShelfLayout.windowSize, ShelfLayout.windowSize(for: .grid), ShelfLayout.capsuleWindowSize] {
            let frame = target.frame(for: size)
            #expect(frame.midX == target.anchor.midX)
            #expect(target.anchor.minY - (frame.maxY - ShelfLayout.shadowInset) == ShelfDockTarget.gap)
            #expect(target.captures(frame.offsetBy(dx: 80, dy: -50)))
            #expect(!target.captures(frame.offsetBy(dx: 0, dy: -53)))
            #expect(!target.captures(frame.offsetBy(dx: 200, dy: 0)))
        }
    }

    @Test func dockedHandleResistsSmallPullsAndFinishesEachNativeDragOnce() {
        _ = NSApplication.shared
        let window = DockingDragTestWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 16),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let handle = HeaderDragView()
        window.contentView = handle
        handle.isDocked = true
        var clicks = 0
        var starts = 0
        var ends = 0
        handle.onClick = { clicks += 1 }
        handle.onBeginDragging = { starts += 1; handle.isDocked = false }
        handle.onEndDragging = { ends += 1 }
        handle.mouseDown(with: mouse(.leftMouseDown, x: 50, window: window))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 70, window: window))
        #expect(handle.isDocked && starts == 0 && window.dragEvent == nil)
        handle.mouseUp(with: mouse(.leftMouseUp, x: 50, window: window))
        #expect(clicks == 0 && ends == 0) // A resisted pull is never a click.
        handle.mouseDown(with: mouse(.leftMouseDown, x: 50, window: window))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 50, window: window))
        #expect(clicks == 1) // An ordinary click still collapses/restores.
        let press = mouse(.leftMouseDown, x: 50, window: window)
        handle.mouseDown(with: press)
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 79, window: window))
        #expect(!handle.isDocked && starts == 1 && window.dragEvent === press)
        handle.mouseUp(with: mouse(.leftMouseUp, x: 79, window: window))
        handle.stopTrackingDrag(completed: true)
        #expect(ends == 1 && clicks == 1)
        handle.mouseDown(with: mouse(.leftMouseDown, x: 50, window: window))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 55, window: window))
        handle.stopTrackingDrag() // Closing/cancelling must not cause a snap.
        #expect(starts == 2 && ends == 1)
    }

    @Test(arguments: [false, true])
    func everyPresentationDocksRetainsItsAnchorAndCanBeDeliberatelyDetached(hasNotch: Bool) async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let target = ShelfDockTarget.target(displayID: 100, frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            notch: hasNotch ? CGRect(x: screen.frame.midX - 100, y: screen.visibleFrame.maxY - 24,
                                     width: 200, height: 24) : nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyDock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("docked".utf8).write(to: file)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        let shelf = ShelfWindowController(store: store, dockTargets: { [target] })
        defer { shelf.stop() }
        for presentation in [ShelfPresentation.stack, .grid, .list] {
            for compact in [false, true] {
                shelf.hide()
                store.add([file])
                store.present(presentation)
                shelf.show(near: CGPoint(x: screen.frame.midX, y: screen.frame.midY), focus: false)
                if compact { shelf.collapse(animated: false) }
                shelf.dragHandle.onBeginDragging?()
                shelf.panel.setFrame(target.frame(for: shelf.panel.frame.size).offsetBy(dx: 30, dy: -30), display: true)
                shelf.dragHandle.onEndDragging?()
                try await Task.sleep(for: .milliseconds(260))
                #expect(shelf.isDocked && shelf.dragHandle.isDocked)
                #expect(shelf.panel.frame == target.frame(for: shelf.panel.frame.size))
                let top = shelf.panel.frame.maxY
                shelf.collapse(animated: false)
                #expect(shelf.panel.frame.maxY == top && shelf.isDocked)
                shelf.show(near: .zero, focus: false, expand: false)
                #expect(shelf.isCollapsed && shelf.panel.frame.maxY == top)
                shelf.restore(animated: false, focus: false)
                #expect(shelf.panel.frame.maxY == top && shelf.isDocked)
                #expect(store.presentation == presentation)
                shelf.show(near: .zero, focus: false)
                #expect(shelf.panel.frame == target.frame(for: shelf.panel.frame.size))
                let alternate: ShelfPresentation = presentation == .stack ? .list : .stack
                store.present(alternate)
                try await Task.sleep(for: .seconds(ShelfLayout.presentationResizeDelay + ShelfLayout.presentationResizeDuration + 0.15))
                #expect(shelf.isDocked)
                #expect(shelf.panel.frame == target.frame(for: ShelfLayout.windowSize(for: alternate)))
                // A pull just past the release threshold is still in the capture
                // zone. Suppress recapture for this gesture so release feels real.
                shelf.dragHandle.onBeginDragging?()
                #expect(!shelf.isDocked && !shelf.dragHandle.isDocked)
                shelf.panel.setFrameOrigin(shelf.panel.frame.origin.applying(CGAffineTransform(translationX: 0, y: -30)))
                shelf.dragHandle.onEndDragging?()
                #expect(!shelf.isDocked)
            }
        }
    }

    @Test func missingTargetOrRemovedDisplayNeverLeavesAnInvisibleDock() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let target = ShelfDockTarget(displayID: 100,
            anchor: CGRect(x: screen.visibleFrame.midX - 100, y: screen.visibleFrame.maxY - 24, width: 200, height: 24),
            visibleFrame: screen.visibleFrame)
        var targets: [ShelfDockTarget] = []
        let shelf = ShelfWindowController(store: ShelfStore(), dockTargets: { targets })
        defer { shelf.stop() }
        shelf.show(near: .zero, focus: false)
        shelf.panel.setFrame(target.frame(for: shelf.panel.frame.size), display: true)
        shelf.dragHandle.onEndDragging?()
        #expect(!shelf.isDocked)
        targets = [target]
        shelf.dragHandle.onEndDragging?()
        try await Task.sleep(for: .milliseconds(260))
        #expect(shelf.isDocked)
        targets = []
        shelf.show(near: screen.visibleFrame.origin, focus: false, expand: false)
        #expect(!shelf.isDocked && !shelf.dragHandle.isDocked)
        #expect(screen.visibleFrame.contains(shelf.panel.frame))
    }
}

@MainActor private final class DockingDragTestWindow: NSWindow {
    var dragEvent: NSEvent?
    override func performDrag(with event: NSEvent) { dragEvent = event }
}
