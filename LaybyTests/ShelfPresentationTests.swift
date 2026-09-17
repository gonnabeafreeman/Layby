import Foundation
import Testing
@testable import LaybyKit

struct ShelfPresentationTests {
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
