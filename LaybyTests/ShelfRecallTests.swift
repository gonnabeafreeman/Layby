import AppKit
import Testing
@testable import LaybyKit

@MainActor @Suite(.serialized)
struct ShelfRecallTests {
    @Test func recallsExpandedCapsuleAndSideTabToDragLocation() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let start = CGPoint(x: bounds.minX + 32, y: bounds.minY + 32)
        let point = CGPoint(x: bounds.maxX - 32, y: bounds.maxY - 32)
        let target = ShelfGeometry.frame(size: ShelfLayout.windowSize, near: point, in: bounds)
        let shelf = ShelfWindowController(store: ShelfStore())
        defer { shelf.stop() }

        for mode in 0..<3 {
            shelf.hide()
            shelf.show(near: start, focus: false)
            if mode == 1 { shelf.collapse(animated: false) }
            if mode == 2 { shelf.collapseToNearestSide(animated: false, edge: .right, on: screen) }
            let origin = shelf.panel.frame
            #expect(origin != target)

            shelf.recall(near: point)
            #expect(shelf.panel.isVisible && !shelf.isCollapsed)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                #expect(shelf.panel.isRecallingShelf)
                if mode == 1 { #expect(shelf.destination.blocksInteraction) }
                if mode == 0 {
                    try await Task.sleep(for: .milliseconds(80))
                    #expect(shelf.panel.frame != origin && shelf.panel.frame != target)
                }
            }
            try await Task.sleep(for: .milliseconds(550))
            #expect(shelf.panel.frame == target)
            #expect(!shelf.panel.isRecallingShelf)
        }
    }

    @Test func recallDetachesTopDockBeforeMoving() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let target = ShelfDockTarget.target(displayID: 100, frame: screen.frame,
            visibleFrame: screen.visibleFrame, notch: nil)
        let shelf = ShelfWindowController(store: ShelfStore(), dockTargets: { [target] })
        defer { shelf.stop() }
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let point = CGPoint(x: bounds.minX + 32, y: bounds.minY + 32)
        let expected = ShelfGeometry.frame(size: ShelfLayout.windowSize, near: point, in: bounds)
        for compact in [false, true] {
            shelf.hide()
            shelf.show(near: CGPoint(x: bounds.midX, y: bounds.midY), focus: false)
            shelf.dragHandle.onBeginDragging?()
            shelf.panel.setFrame(target.frame(for: shelf.panel.frame.size), display: true)
            shelf.dragHandle.onEndDragging?()
            try await Task.sleep(for: .milliseconds(260))
            #expect(shelf.isDocked)

            if compact { shelf.collapse(animated: false) }
            shelf.recall(near: point)
            #expect(!shelf.isDocked && !shelf.isCollapsed)
            try await Task.sleep(for: .milliseconds(550))
            #expect(shelf.panel.frame == expected)
        }
    }
}
