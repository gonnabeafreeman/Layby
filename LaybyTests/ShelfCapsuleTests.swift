import AppKit
import SwiftUI
import Testing
@testable import LaybyKit

@MainActor @Suite(.serialized)
struct ShelfCapsuleTests {
    private func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 8, window: NSWindow,
                       clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    @Test func headerClickCollapsesButDragAndOutsideReleaseDoNot() {
        _ = NSApplication.shared
        let window = HeaderDragTestWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 16),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let handle = HeaderDragView()
        window.contentView = handle
        var clicks = 0
        var drags = 0
        handle.onClick = { clicks += 1 }
        handle.onBeginDragging = { drags += 1 }
        handle.mouseDown(with: mouse(.leftMouseDown, x: 50, window: window))
        #expect(clicks == 0 && drags == 0)
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 52, window: window))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 52, window: window))
        #expect(clicks == 1 && drags == 0)

        let down = mouse(.leftMouseDown, x: 50, window: window)
        handle.mouseDown(with: down)
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 55, window: window))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 50, window: window))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 50, window: window))
        #expect(clicks == 1 && drags == 1)
        #expect(window.dragEvent === down)

        handle.mouseDown(with: mouse(.leftMouseDown, x: 50, window: window))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 150, window: window))
        #expect(clicks == 1)
        #expect(handle.accessibilityPerformPress())
        #expect(clicks == 2)
        #expect(!HeaderDragView().accessibilityPerformPress())
    }

    @Test func hoverSurvivesTrackingUpdatesAndStaleExitEventsDuringResize() async throws {
        _ = NSApplication.shared
        let window = HeaderDragTestWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 16),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let handle = HeaderDragView()
        window.contentView = handle
        let grip = try #require(handle.layer?.sublayers?.first)
        window.testMouseLocation = CGPoint(x: 50, y: 8)
        handle.updateTrackingAreas()
        let tracking = try #require(handle.trackingAreas.first { ($0.owner as? HeaderDragView) === handle })
        handle.mouseEntered(with: mouse(.leftMouseDown, x: 50, window: window))
        #expect(grip.bounds.width == 80)
        grip.removeAllAnimations() // The pointer has already settled over the grip.
        for _ in 0..<3 {
            handle.preserveHoverDuringLayout {
                // Model the transient mismatch between NSWindow and NSView
                // coordinates while the wide list/grid window is resized.
                window.testMouseLocation = CGPoint(x: 250, y: 8)
                handle.updateTrackingAreas()
                handle.mouseExited(with: mouse(.leftMouseDown, x: 250, window: window))
                #expect(grip.bounds.width == 80)
                #expect(grip.opacity == 0.9)
                #expect(grip.animation(forKey: "hover") == nil)
                window.testMouseLocation = CGPoint(x: 50, y: 8)
            }
            try await Task.sleep(for: .milliseconds(20))
            // A queued exit from the old geometry must not shorten the grip.
            handle.mouseExited(with: mouse(.leftMouseDown, x: 250, window: window))
            handle.mouseEntered(with: mouse(.leftMouseDown, x: 50, window: window))
            let ownedAreas = handle.trackingAreas.filter { ($0.owner as? HeaderDragView) === handle }
            #expect(ownedAreas.count == 1)
            #expect(ownedAreas.first === tracking)
            #expect(grip.bounds.width == 80)
            #expect(grip.animation(forKey: "hover") == nil)
        }
        // A real exit still gets the usual hover feedback.
        // Let the final resize reconciliation leave its temporary protection
        // before modelling a genuine pointer exit.
        try await Task.sleep(for: .milliseconds(100))
        window.testMouseLocation = CGPoint(x: 150, y: 8)
        handle.mouseExited(with: mouse(.leftMouseDown, x: 150, window: window))
        #expect(grip.bounds.width == 80 * 0.32)
        #expect(grip.opacity == 0.72)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(grip.animation(forKey: "hover") != nil)
        }
    }

    @Test func sideTabRetainsFullShelfSizeAndRestoreReturnsItsFrame() throws {
        _ = NSApplication.shared
        let shelf = ShelfWindowController(store: ShelfStore())
        defer { shelf.stop() }
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        let original = shelf.panel.frame
        let screen = try #require(shelf.panel.screen ?? NSScreen.main)

        shelf.collapseToNearestSide(animated: false)
        #expect(shelf.isCollapsed)
        #expect(shelf.panel.frame.width == original.width)
        #expect(shelf.panel.frame.height == original.height)
        let content = shelf.panel.frame.insetBy(dx: ShelfLayout.shadowInset, dy: ShelfLayout.shadowInset)
        if original.midX < screen.frame.midX {
            #expect(content.maxX - screen.frame.minX == ShelfLayout.sideRevealWidth)
        } else {
            #expect(screen.frame.maxX - content.minX == ShelfLayout.sideRevealWidth)
        }

        shelf.restore(animated: false, focus: false)
        #expect(!shelf.isCollapsed)
        #expect(shelf.panel.frame == original)
    }

    @Test func sideTabMovesVerticallyThenRevealsAndContinuesDragging() throws {
        let shelf = ShelfWindowController(store: ShelfStore())
        defer { shelf.stop() }
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        let originalSize = shelf.panel.frame.size
        let screen = try #require(shelf.panel.screen ?? NSScreen.main)
        let left = shelf.panel.frame.midX < screen.frame.midX
        shelf.collapseToNearestSide(animated: false)
        let initial = shelf.panel.frame
        let start = CGPoint(x: left ? screen.frame.minX + 18 : screen.frame.maxX - 18, y: initial.midY)
        shelf.handleSidePointer(.leftMouseDown, at: start)
        let moved = CGPoint(x: start.x, y: start.y + 10)
        shelf.handleSidePointer(.leftMouseDragged, at: moved)
        #expect(shelf.isCollapsed)
        #expect(shelf.panel.frame.minY == initial.minY + 10)
        let pulled = CGPoint(x: moved.x + (left ? 40 : -40), y: moved.y)
        shelf.handleSidePointer(.leftMouseDragged, at: pulled)
        #expect(shelf.isCollapsed)
        #expect(shelf.panel.frame.minX == initial.minX + (left ? 40 : -40))
        #expect(shelf.panel.frame.size == originalSize)
        let content = try #require(shelf.destination.subviews.compactMap { $0 as? NSHostingView<ShelfView> }.first)
        #expect(content.alphaValue > 0 && content.alphaValue < 1)
        // Reverse the drag: both window and content blend must retrace the path.
        shelf.handleSidePointer(.leftMouseDragged, at: moved)
        #expect(shelf.panel.frame.minX == initial.minX)
        #expect(content.alphaValue == 0)
        let distance = originalSize.width - ShelfLayout.shadowInset * 2
        let continued = CGPoint(x: start.x + (left ? distance : -distance), y: pulled.y - 30)
        shelf.handleSidePointer(.leftMouseDragged, at: continued)
        #expect(content.alphaValue == 1)
        #expect(shelf.panel.frame.minX == initial.minX + (left ? distance : -distance))
        let revealed = shelf.panel.frame
        shelf.handleSidePointer(.leftMouseUp, at: continued)
        #expect(!shelf.isCollapsed)
        #expect(shelf.panel.frame == revealed)
    }

    @Test func clicksRespondImmediatelyWithoutSideCapture() {
        let window = HeaderDragTestWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 16),
            styleMask: .borderless, backing: .buffered, defer: false)
        let handle = HeaderDragView()
        window.contentView = handle
        var clicks = 0
        handle.onClick = { clicks += 1 }
        handle.mouseDown(with: mouse(.leftMouseDown, x: 50, window: window))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 50, window: window))
        #expect(clicks == 1)
        handle.mouseDown(with: mouse(.leftMouseDown, x: 50, window: window, clickCount: 2))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 50, window: window, clickCount: 2))
        #expect(clicks == 2)
    }

    @Test func secondClickDuringToggleReachesHandleWithoutSideCapture() throws {
        let shelf = ShelfWindowController(store: ShelfStore())
        defer { shelf.stop() }
        for startsCollapsed in [false, true] {
            shelf.hide()
            shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
            let size = shelf.panel.frame.size
            if startsCollapsed { shelf.collapse(animated: false) }
            shelf.dragHandle.onClick?()
            shelf.panel.contentView?.layoutSubtreeIfNeeded()
            let handle = shelf.dragHandle
            let point = shelf.destination.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), from: handle)
            let hit = shelf.destination.hitTest(shelf.destination.convert(point, to: shelf.destination.superview))
            #expect(hit === handle)
            handle.onClick?()
            #expect(!shelf.panel.permitsSideCollapse)
            shelf.restore(animated: false, focus: false)
            #expect(!shelf.isCollapsed)
            #expect(shelf.panel.frame.size == size)
        }
    }

    @Test func allPresentationsAbsorbContentIntoOneStationaryHandle() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyHandle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("retained".utf8).write(to: file)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([file])
        try await settle(store)
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop() }
        let handle = shelf.dragHandle
        let grip = try #require(handle.layer?.sublayers?.first)
        func screenFrame() -> CGRect {
            shelf.panel.contentView?.layoutSubtreeIfNeeded()
            return shelf.panel.convertToScreen(handle.convert(handle.bounds, to: nil))
        }
        func checkPersistentHandle(at frame: CGRect) {
            #expect(shelf.dragHandle === handle)
            #expect(handle.layer?.sublayers?.first === grip)
            #expect(handle.superview === shelf.destination)
            #expect(shelf.destination.subviews.compactMap { $0 as? HeaderDragView }.count == 1)
            #expect(screenFrame() == frame)
            #expect(CATransform3DIsIdentity(handle.layer!.transform))
            #expect(CATransform3DIsIdentity(shelf.destination.layer!.transform))
            #expect(handle.layer?.animation(forKey: "layby.collapse") == nil)
        }
        for presentation in [ShelfPresentation.stack, .grid, .list] {
            store.present(presentation)
            shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
            let original = screenFrame()
            #expect(shelf.panel.frame.maxY - original.maxY == ShelfLayout.shadowInset + ShelfLayout.handleTopInset)
            #expect(handle.accessibilityPerformPress())
            checkPersistentHandle(at: original)
            let capsule = try #require(shelf.destination.subviews.compactMap { $0 as? NSHostingView<ShelfCapsuleView> }.first)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                #expect(capsule.isHidden)
                let content = try #require(shelf.destination.subviews.compactMap { $0 as? NSHostingView<ShelfView> }.first)
                let layer = try #require(content.layer)
                let group = try #require(layer.animation(forKey: "layby.collapse") as? CAAnimationGroup)
                let animations = try #require(group.animations)
                let movement = try #require(animations.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "position" })
                let shrink = try #require(animations.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform" })
                let fade = try #require(animations.compactMap { $0 as? CAKeyframeAnimation }.first { $0.keyPath == "opacity" })
                #expect(fade.values as? [Int] == [1, 1, 0])
                #expect(group.duration == ShelfLayout.collapseDuration)
                let start = try #require((movement.fromValue as? NSValue)?.pointValue)
                let end = try #require((movement.toValue as? NSValue)?.pointValue)
                let finalScale = try #require((shrink.toValue as? NSValue)?.caTransform3DValue)
                let parent = try #require(layer.superlayer)
                let handleLayer = try #require(handle.layer)
                let sink = parent.convert(CGPoint(x: handleLayer.bounds.midX, y: handleLayer.bounds.midY), from: handleLayer)
                // Reproduce the animated geometry on an invisible layer, using
                // Core Animation's conversion rather than assuming a Y direction.
                let probe = CALayer()
                probe.bounds = layer.bounds
                probe.anchorPoint = layer.anchorPoint
                probe.isGeometryFlipped = layer.isGeometryFlipped
                probe.isHidden = true
                parent.addSublayer(probe)
                defer { probe.removeFromSuperlayer() }
                let points = [CGPoint(x: layer.bounds.midX, y: layer.bounds.midY),
                              CGPoint(x: layer.bounds.minX, y: layer.bounds.minY),
                              CGPoint(x: layer.bounds.maxX, y: layer.bounds.maxY)]
                var distances = [CGFloat](repeating: .greatestFiniteMagnitude, count: points.count)
                for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                    probe.position = CGPoint(x: start.x + (end.x - start.x) * progress,
                                             y: start.y + (end.y - start.y) * progress)
                    probe.transform = CATransform3DMakeScale(1 + (finalScale.m11 - 1) * progress,
                                                            1 + (finalScale.m22 - 1) * progress, 1)
                    for (index, point) in points.enumerated() {
                        let current = parent.convert(point, from: probe)
                        let distance = hypot(current.x - sink.x, current.y - sink.y)
                        #expect(distance <= distances[index] + 0.01)
                        distances[index] = distance
                    }
                }
                #expect(distances[0] < 0.01)
                #expect(distances.allSatisfy { $0 < 2 })
            }
            try await Task.sleep(for: .milliseconds(320))
            checkPersistentHandle(at: original)
            #expect(handle.isCollapsed)
            #expect(!capsule.isHidden)
            #expect(capsule.frame.size == ShelfLayout.capsuleSize)
            // The same handle can also restore the shelf, retaining its identity.
            #expect(handle.accessibilityPerformPress())
            try await Task.sleep(for: .milliseconds(320))
            checkPersistentHandle(at: original)
            #expect(!handle.isCollapsed && !shelf.isCollapsed)
            #expect(store.presentation == presentation)
        }
        shelf.hide()
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        #expect(shelf.dragHandle === handle)
        #expect(handle.layer?.sublayers?.first === grip)
    }

    @Test func collapseAnimationEndsAtTopCenterAndCannotReCollapseAfterRestore() async throws {
        _ = NSApplication.shared
        let shelf = ShelfWindowController(store: ShelfStore())
        defer { shelf.stop() }
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        let original = shelf.panel.frame
        shelf.collapse()
        #expect(shelf.isCollapsed)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(shelf.destination.blocksInteraction)
            #expect(shelf.panel.frame == original)
        }
        try await Task.sleep(for: .milliseconds(320))
        #expect(!shelf.destination.blocksInteraction)
        #expect(shelf.panel.frame.size == ShelfLayout.capsuleWindowSize)
        #expect(shelf.panel.frame.maxY == original.maxY)
        #expect(shelf.panel.frame.midX == original.midX)
        shelf.restore(animated: false, focus: false)
        shelf.collapse()
        shelf.restore(animated: false, focus: false)
        try await Task.sleep(for: .milliseconds(320))
        #expect(!shelf.isCollapsed && shelf.panel.frame == original)
        #expect(!shelf.destination.blocksInteraction)
    }

    @Test func expansionReleasesContentSymmetricallyFromStationaryHandle() async throws {
        _ = NSApplication.shared
        let store = ShelfStore()
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop() }
        for presentation in [ShelfPresentation.stack, .grid, .list] {
            store.present(presentation)
            shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
            let original = shelf.panel.frame
            shelf.collapse(animated: false)
            let handle = shelf.dragHandle
            let grip = try #require(handle.layer?.sublayers?.first)
            let handleFrame = shelf.panel.convertToScreen(handle.convert(handle.bounds, to: nil))
            #expect(handle.accessibilityPerformPress())
            // The native window immediately has its final viewport; only its
            // visible layers animate, avoiding independent window-edge motion.
            #expect(shelf.panel.frame == original)
            #expect(handleFrame == shelf.panel.convertToScreen(handle.convert(handle.bounds, to: nil)))
            #expect(handle.layer?.sublayers?.first === grip)
            #expect(handle.layer?.animation(forKey: "layby.expand") == nil)
            let content = try #require(shelf.destination.subviews.compactMap { $0 as? NSHostingView<ShelfView> }.first)
            let glass = try #require(shelf.panel.contentView?.subviews.compactMap { $0 as? ShelfGlassView }.first)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                #expect(shelf.destination.blocksInteraction)
                for view in [content as NSView, glass] {
                    let layer = try #require(view.layer)
                    let parent = try #require(layer.superlayer)
                    let handleLayer = try #require(handle.layer)
                    let sink = parent.convert(CGPoint(x: handleLayer.bounds.midX, y: handleLayer.bounds.midY), from: handleLayer)
                    let group = try #require(layer.animation(forKey: "layby.expand") as? CAAnimationGroup)
                    let animations = try #require(group.animations)
                    let movement = try #require(animations.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "position" })
                    let scale = try #require(animations.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform" })
                    let start = try #require((movement.fromValue as? NSValue)?.pointValue)
                    let end = try #require((movement.toValue as? NSValue)?.pointValue)
                    let initialScale = try #require((scale.fromValue as? NSValue)?.caTransform3DValue)
                    let finalScale = try #require((scale.toValue as? NSValue)?.caTransform3DValue)
                    #expect(CATransform3DIsIdentity(finalScale))
                    if view === content {
                        let fade = try #require(animations.compactMap { $0 as? CAKeyframeAnimation }.first)
                        #expect(fade.values as? [Int] == [0, 1, 1])
                        #expect(initialScale.m11 == 0.005)
                    } else {
                        #expect(abs(layer.bounds.width * initialScale.m11 - ShelfLayout.capsuleSize.width) < 0.01)
                        #expect(abs(layer.bounds.height * initialScale.m22 - ShelfLayout.capsuleSize.height) < 0.01)
                    }
                    let probe = CALayer()
                    probe.bounds = layer.bounds
                    probe.anchorPoint = layer.anchorPoint
                    probe.isGeometryFlipped = layer.isGeometryFlipped
                    probe.isHidden = true
                    parent.addSublayer(probe)
                    defer { probe.removeFromSuperlayer() }
                    var previousWidth: CGFloat = 0
                    var previousDistance: CGFloat = 0
                    for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                        probe.position = CGPoint(x: start.x + (end.x - start.x) * progress,
                                                 y: start.y + (end.y - start.y) * progress)
                        probe.transform = CATransform3DMakeScale(initialScale.m11 + (1 - initialScale.m11) * progress,
                                                                initialScale.m22 + (1 - initialScale.m22) * progress, 1)
                        let left = parent.convert(CGPoint(x: probe.bounds.minX, y: probe.bounds.midY), from: probe)
                        let right = parent.convert(CGPoint(x: probe.bounds.maxX, y: probe.bounds.midY), from: probe)
                        let width = right.x - left.x
                        let distance = abs(left.y - sink.y)
                        #expect(abs((left.x + right.x) / 2 - sink.x) < 0.01)
                        #expect(width >= previousWidth)
                        #expect(distance >= previousDistance - 0.01)
                        if progress == 0 { #expect(distance < 0.01) }
                        previousWidth = width
                        previousDistance = distance
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(340))
            #expect(!shelf.destination.blocksInteraction)
            #expect(content.layer?.animation(forKey: "layby.expand") == nil)
            #expect(glass.layer?.animation(forKey: "layby.expand") == nil)
            #expect(shelf.panel.frame == original)
        }
    }

    @Test func interruptedExpansionDoesNotLeaveAnimationsOrBlockedInput() async throws {
        _ = NSApplication.shared
        let shelf = ShelfWindowController(store: ShelfStore())
        defer { shelf.stop() }
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        shelf.collapse(animated: false)
        shelf.restore()
        shelf.collapse(animated: false)
        try await Task.sleep(for: .milliseconds(340))
        #expect(shelf.isCollapsed && !shelf.destination.blocksInteraction)
        #expect(shelf.panel.frame.size == ShelfLayout.capsuleWindowSize)
        shelf.restore()
        shelf.hide()
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        try await Task.sleep(for: .milliseconds(340))
        #expect(!shelf.isCollapsed && !shelf.destination.blocksInteraction)
        #expect(shelf.panel.frame.size == ShelfLayout.windowSize)
        #expect(shelf.panel.contentView?.layer?.animation(forKey: "layby.expand") == nil)
    }

    private func settle(_ store: ShelfStore) async throws {
        for _ in 0..<200 {
            if !store.items.contains(where: { $0.state == .loading }) && !store.folderBrowser.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("File inspection did not finish")
    }

    @Test func collapseRetainsBrowserAndNativeDropAppendsWithoutLeavingFolder() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyCapsule-\(UUID())")
        let managed = ManagedFileStore(root: root)
        var directory: ManagedFileDirectory? = try managed.makeDestination()
        let folder = try #require(directory?.url)
        let child = folder.appendingPathComponent("child.txt")
        try Data("retained".utf8).write(to: child)
        let incoming = root.appendingPathComponent("incoming.txt")
        try Data("incoming".utf8).write(to: incoming)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(managedFiles: managed)
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop() }
        store.add([folder], managedDirectory: directory)
        directory = nil
        try await settle(store)
        store.present(.list)
        store.openFolder(try #require(store.items.first?.id))
        try await settle(store)
        let selected = try #require(store.visibleItems.first?.id)
        store.select(selected, extending: false)
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        shelf.panel.contentView?.layoutSubtreeIfNeeded()
        let host = try #require(shelf.destination.subviews.compactMap { $0 as? NSHostingView<ShelfView> }.first)
        let viewport = host.frame.size
        let originalFrame = shelf.panel.frame
        var collapsed = 0
        shelf.onCollapse = { collapsed += 1 }
        shelf.collapse(animated: false)
        shelf.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(collapsed == 1)
        #expect(shelf.isCollapsed && shelf.panel.isVisible)
        #expect(shelf.panel.frame.size == ShelfLayout.capsuleWindowSize)
        #expect(host.isHidden && host.frame.size == viewport)
        #expect(store.selection == [selected])
        #expect(store.folderBrowser.directory?.url == folder)
        #expect(store.presentation == .list)
        #expect(try String(contentsOf: child, encoding: .utf8) == "retained")
        // Hidden rows must not be deleted, selected or navigated from the capsule.
        shelf.panel.onDelete?()
        shelf.panel.onSelectAll?()
        #expect(shelf.panel.onNavigate?(.down) == false)
        #expect(store.selection == [selected])

        let drop = CapsuleDropInfo(url: incoming, window: shelf.panel)
        defer { drop.draggingPasteboard.releaseGlobally() }
        #expect(shelf.destination.draggingEntered(drop) == .copy)
        shelf.restore(animated: false)
        #expect(shelf.isCollapsed)
        #expect(shelf.destination.performDragOperation(drop))
        try await settle(store)
        #expect(store.items.count == 2)
        #expect(store.folderBrowser.directory?.url == folder)
        #expect(store.selection == [selected])
        #expect(!store.isDropTargeted)
        #expect(shelf.isCollapsed && shelf.panel.frame.size == ShelfLayout.capsuleWindowSize)
        shelf.restore(animated: false, focus: false)
        shelf.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(!shelf.isCollapsed && !host.isHidden)
        #expect(shelf.panel.frame == originalFrame)
        #expect(shelf.destination.subviews.contains { $0 === host })
        #expect(store.presentation == .list && store.selection == [selected])
    }

    @Test func movedCapsuleRestoresAtNewLocationAndAutomaticActivationKeepsItCompact() throws {
        _ = NSApplication.shared
        let store = ShelfStore()
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop() }
        let screen = try #require(NSScreen.main)
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        shelf.show(near: CGPoint(x: bounds.midX, y: bounds.midY), focus: false)
        store.isDraggingOut = true
        shelf.collapse(animated: false)
        #expect(!shelf.isCollapsed)
        store.isDraggingOut = false
        store.isDropTargeted = true
        shelf.collapse(animated: false)
        #expect(!shelf.isCollapsed)
        store.isDropTargeted = false
        let original = shelf.panel.frame
        shelf.collapse(animated: false)
        let capsule = shelf.panel.frame
        shelf.show(near: .zero, focus: false, expand: false)
        #expect(shelf.isCollapsed && shelf.panel.frame == capsule)
        shelf.panel.setFrameOrigin(CGPoint(x: capsule.minX - 20, y: capsule.minY - 20))
        shelf.restore(animated: false, focus: false)
        let expected = ShelfGeometry.resizedFrame(original.offsetBy(dx: -20, dy: -20), size: original.size, in: bounds)
        #expect(shelf.panel.frame == expected)
        shelf.collapse(animated: false)
        shelf.show(near: CGPoint(x: bounds.midX, y: bounds.midY), focus: false)
        #expect(!shelf.isCollapsed)
        shelf.collapse(animated: false)
        shelf.hide()
        #expect(!shelf.isCollapsed && !shelf.panel.isVisible)
        #expect(shelf.destination.subviews.count == 1)
        #expect(shelf.destination.subviews.first === shelf.dragHandle)
        shelf.show(near: CGPoint(x: bounds.midX, y: bounds.midY), focus: false)
        #expect(!shelf.isCollapsed && shelf.panel.frame.size == ShelfLayout.windowSize)
    }
}

@MainActor private final class HeaderDragTestWindow: NSWindow {
    var testMouseLocation: CGPoint?
    override var mouseLocationOutsideOfEventStream: NSPoint {
        testMouseLocation ?? super.mouseLocationOutsideOfEventStream
    }
    var dragEvent: NSEvent?
    override func performDrag(with event: NSEvent) { dragEvent = event }
}

/// Exercise the real AppKit drop callbacks with a private test pasteboard.
private final class CapsuleDropInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingLocation: NSPoint = .zero
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 901
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(url: URL, window: NSWindow) {
        draggingDestinationWindow = window
        super.init()
        draggingPasteboard.writeObjects([url as NSURL])
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
