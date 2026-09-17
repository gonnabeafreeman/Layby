import AppKit
import SwiftUI
import Testing
@testable import LaybyKit

@MainActor @Suite(.serialized)
struct ShelfAppearanceTests {
    @Test func onlyVisibleCapsuleUpdatesAppearanceAndExpansionRetainsIt() async throws {
        _ = NSApplication.shared
        let shelf = ShelfWindowController(store: ShelfStore())
        defer { shelf.stop() }
        let surface = try #require(shelf.panel.contentView)
        let glass = try #require(surface.subviews.compactMap { $0 as? ShelfGlassView }.first)
        let grip = try #require(shelf.dragHandle.layer?.sublayers?.first)
        var schemes: [ColorScheme] = []
        let nested = NSHostingView(rootView: AppearanceProbe { schemes.append($0) })
        nested.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        shelf.destination.addSubview(nested)
        defer { nested.removeFromSuperview() }

        func check(_ name: NSAppearance.Name) async throws {
            surface.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            for view in [glass.expandedEffect, glass.expandedContent, shelf.destination, shelf.dragHandle, nested] {
                #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name)
            }
            for host in shelf.destination.subviews where host is NSHostingView<ShelfView> || host is NSHostingView<ShelfCapsuleView> {
                #expect(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name)
            }
            #expect(schemes.last == (name == .darkAqua ? .dark : .light))
            let color = try #require(grip.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.genericGray) })
            #expect(name == .darkAqua ? color.whiteComponent > 0.8 : color.whiteComponent < 0.3)
            #expect(shelf.dragHandle.layer?.sublayers?.first === grip)
        }

        for mode in [ShelfPresentation.stack, .grid, .list] {
            shelf.hide()
            shelf.panel.appearance = NSAppearance(named: .aqua)
            shelf.destination.store.present(mode)
            shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
            // Hidden capsule changes must not affect a newly opened large panel.
            glass.capsuleContent.appearance = NSAppearance(named: .darkAqua)
            glass.capsuleContent.refreshAppearance()
            try await check(.aqua)
            guard #available(macOS 26.0, *),
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { continue }
            for name in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
                shelf.collapse(animated: false)
                glass.capsuleContent.appearance = NSAppearance(named: name)
                glass.capsuleContent.refreshAppearance()
                try await check(name)
                #expect(glass.capsuleEffect.appearance == nil)
                shelf.restore(animated: false, focus: false)
                try await check(name)
                // Neither a hidden renderer nor the system theme replaces the snapshot.
                let opposite: NSAppearance.Name = name == .aqua ? .darkAqua : .aqua
                glass.capsuleContent.appearance = NSAppearance(named: opposite)
                glass.capsuleContent.refreshAppearance()
                shelf.panel.appearance = NSAppearance(named: opposite)
                try await check(name)
            }
        }
        shelf.hide()
        shelf.panel.appearance = NSAppearance(named: .aqua)
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        try await check(.aqua)
    }

    @Test func opaqueAccessibilityBackgroundRefreshesWithLocalAppearance() throws {
        let fill = ShelfGlassContentView(frame: .zero)
        var colors: [CGColor] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            fill.appearance = NSAppearance(named: name)
            fill.updateBackground(reduceTransparency: true)
            let actual = try #require(fill.layer?.backgroundColor)
            fill.effectiveAppearance.performAsCurrentDrawingAppearance {
                #expect(actual == NSColor.windowBackgroundColor.cgColor)
            }
            colors.append(actual)
        }
        #expect(colors[0] != colors[1])
        fill.updateBackground(reduceTransparency: false)
        #expect(fill.layer?.backgroundColor?.alpha == 0)
    }

    @Test func glassSurfaceUsesAdaptiveOutlineAndCenteredShadow() throws {
        let shelf = ShelfWindowController(store: ShelfStore())
        defer { shelf.stop() }
        let surface = try #require(shelf.panel.contentView as? ShelfSurfaceView)
        let glass = try #require(surface.subviews.compactMap { $0 as? ShelfGlassView }.first)
        surface.layoutSubtreeIfNeeded()

        #expect(surface.layer?.shadowOffset == .zero)
        #expect(surface.layer?.shadowRadius == ShelfLayout.surfaceShadowRadius)
        #expect(surface.layer?.shadowOpacity == ShelfLayout.surfaceShadowOpacity)
        #expect(glass.layer?.borderWidth == 1)

        glass.appearance = NSAppearance(named: .aqua)
        glass.viewDidChangeEffectiveAppearance()
        let lightOutline = try #require(glass.layer?.borderColor)
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.viewDidChangeEffectiveAppearance()
        let darkOutline = try #require(glass.layer?.borderColor)
        #expect(lightOutline != darkOutline)
    }
}

private struct AppearanceProbe: View {
    @Environment(\.colorScheme) private var colorScheme
    let report: (ColorScheme) -> Void

    var body: some View {
        Color.clear.onChange(of: colorScheme, initial: true) { _, value in report(value) }
    }
}
