import AppKit
import SwiftUI
import Testing
@testable import LaybyKit

struct ShelfPresentationTests {
    /// A stack parked flush against a screen edge must still open a full-size
    /// grid or list — sliding away from the edge like expanding out of the
    /// capsule does, rather than clipping the expanded content to fit in place.
    @MainActor @Test func presentationNearAScreenEdgeSlidesInsteadOfShrinking() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyPresentationEdge-\(UUID()).txt")
        try Data("test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ShelfStore()
        store.add([file])
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop() }
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        let screen = try #require(shelf.panel.screen ?? NSScreen.main)
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let stackSize = ShelfLayout.windowSize(for: .stack)
        // Flush against the left edge: nowhere near enough room on that side
        // for the expanded size to grow into without moving.
        shelf.panel.setFrame(CGRect(x: bounds.minX, y: bounds.minY, width: stackSize.width, height: stackSize.height),
                             display: false)
        store.present(.grid)
        try await Task.sleep(for: .milliseconds(700))
        let expandedSize = ShelfLayout.windowSize(for: .grid)
        #expect(shelf.panel.frame.width == expandedSize.width)
        #expect(shelf.panel.frame.height == expandedSize.height)
        #expect(bounds.contains(shelf.panel.frame))
    }

    @MainActor @Test func presentationOverlapsFadeAndResizeThenCommitsContent() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyTransition-\(UUID()).txt")
        try Data("test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ShelfStore()
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop() }
        store.add([file])
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        for mode in [ShelfPresentation.list, .stack] {
            let previous = store.displayedPresentation
            let before = shelf.panel.frame
            let outgoing = try #require(shelf.destination.subviews.compactMap { $0 as? NSHostingView<ShelfView> }.first)
            store.present(mode)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                #expect(store.displayedPresentation == previous)
                #expect(shelf.panel.frame == before)
                #expect(shelf.destination.blocksInteraction)
                try await Task.sleep(for: .milliseconds(70))
                #expect(store.displayedPresentation == previous)
            }
            try await Task.sleep(for: .milliseconds(500))
            #expect(store.displayedPresentation == mode)
            let incoming = try #require(shelf.destination.subviews.compactMap { $0 as? NSHostingView<ShelfView> }.first)
            #expect(incoming !== outgoing)
            #expect(outgoing.isHidden && outgoing.superview == nil)
            #expect(incoming.alphaValue == 1 && !incoming.isHidden)
            #expect(shelf.destination.subviews.compactMap { $0 as? NSHostingView<ShelfView> }.count == 1)
            #expect(!shelf.destination.blocksInteraction)
            #expect(shelf.panel.frame.maxY == before.maxY)
            #expect(shelf.panel.frame.midX == before.midX)
        }
        // A rapid reversal must not allow the first fade's completion to reveal
        // stale content or leave the new host transparent.
        store.present(.list)
        try await Task.sleep(for: .milliseconds(60))
        store.present(.stack)
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.displayedPresentation == .stack)
        let host = try #require(shelf.destination.subviews.compactMap { $0 as? NSHostingView<ShelfView> }.first)
        #expect(host.alphaValue == 1 && !host.isHidden)
        #expect(!shelf.destination.blocksInteraction)
        store.present(.list)
        shelf.hide()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!shelf.panel.isVisible)
        #expect(store.displayedPresentation == .stack)
        #expect(!shelf.destination.blocksInteraction)
    }
    @Test func sideCaptureRequiresThirtyPercentHiddenArea() {
        let screen = CGRect(x: -1000, y: 0, width: 1000, height: 900)
        let center = CGRect(x: -600, y: 300, width: 200, height: 220)
        #expect(ShelfGeometry.sideCapture(content: center, screen: screen) == nil)
        #expect(ShelfGeometry.sideCapture(content: CGRect(x: -141, y: 300, width: 200, height: 220), screen: screen) == nil)
        #expect(ShelfGeometry.sideCapture(content: CGRect(x: -140, y: 300, width: 200, height: 220), screen: screen) == .right)
        #expect(ShelfGeometry.sideCapture(content: CGRect(x: -1060, y: 300, width: 200, height: 220), screen: screen) == .left)
    }
    @Test func expansionKeepsTopCenterWhenSpaceAllows() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let original = CGRect(x: 400, y: 400, width: 360, height: 380)
        let expanded = ShelfGeometry.resizedFrame(original, size: CGSize(width: 660, height: 480), in: bounds)
        #expect(expanded.midX == original.midX)
        #expect(expanded.maxY == original.maxY)
        let compact = ShelfGeometry.resizedFrame(expanded, size: original.size, in: bounds)
        #expect(compact == original)
    }

    @Test func expansionClampsToNegativeCoordinateAndSmallDisplays() {
        for bounds in [CGRect(x: -1440, y: -200, width: 1440, height: 900),
                       CGRect(x: 0, y: 0, width: 500, height: 350)] {
            let original = CGRect(x: bounds.minX, y: bounds.minY, width: 360, height: 380)
            let expanded = ShelfGeometry.resizedFrame(original, size: CGSize(width: 660, height: 480), in: bounds)
            #expect(bounds.contains(expanded))
        }
    }
}
