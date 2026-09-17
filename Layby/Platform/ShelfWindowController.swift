import AppKit
import QuartzCore
import Quartz
import SwiftUI

@MainActor
final class ShelfPanel: NSPanel {
    var isDocked = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Only transparent shadow padding may extend into the menu bar while docked.
        if isDocked, let screen = screen ?? self.screen,
           screen.visibleFrame.contains(frameRect.insetBy(dx: ShelfLayout.shadowInset,
                                                          dy: ShelfLayout.shadowInset)) {
            return frameRect
        }
        return super.constrainFrameRect(frameRect, to: screen)
    }

    weak var services: ShelfServicesController?
    var permitsFileServices = true
    var onHide: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onCopy: (() -> Void)?
    var onQuickLook: (() -> Bool)?
    var onNavigate: ((ShelfNavigationDirection) -> Bool)?
    var dismissQuickLook: (() -> Bool)?
    weak var quickLook: ShelfQuickLookController?
    weak var selectionBackground: ShelfSelectionBackgroundView?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func close() { onHide?() }
    override func performClose(_ sender: Any?) { close() }
    override func cancelOperation(_ sender: Any?) {
        if dismissQuickLook?() != true { onHide?() }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLook?.hasItems == true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook?.beginControl(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook?.endControl(panel) }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if permitsFileServices, services?.accepts(sendType: sendType, returnType: returnType) == true { return services }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { selectionBackground?.handleMouseDown(event) }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if handleQuickLookKey(event) || handleNavigationKey(event) { return }
        super.keyDown(with: event)
    }

    func handleQuickLookKey(_ event: NSEvent) -> Bool {
        guard ShelfQuickLookController.isToggleKey(event) else { return false }
        // Holding Space must not repeatedly open and close the panel.
        return event.isARepeat || onQuickLook?() == true
    }

    static func navigationDirection(for event: NSEvent) -> ShelfNavigationDirection? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard let direction = Self.navigationDirection(for: event) else { return false }
        return onNavigate?(direction) ?? false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleQuickLookKey(event) || handleNavigationKey(event) { return true }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": onSelectAll?(); return true
            case "c": onCopy?(); return true
            case "w": onHide?(); return true
            default: break
            }
        }
        if event.keyCode == 53 { cancelOperation(nil); return true }
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// A transparent window surface with an explicit rounded shadow, independent of key state.
@MainActor
final class ShelfSurfaceView: NSView {
    private static let appearanceAnimationKey = "layby.appearance"
    var cornerRadius: CGFloat = ShelfLayout.cornerRadius { didSet { needsLayout = true } }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
        layer?.backgroundColor = NSColor.clear.cgColor
        applyElevation()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyElevation()
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: ShelfLayout.shadowInset, dy: ShelfLayout.shadowInset),
                                  cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.commit()
    }

    private func applyElevation() {
        layer?.shadowColor = NSColor.black.cgColor
        // A centered shadow creates depth on every edge instead of making the
        // shelf look like it is lit only from above.
        layer?.shadowOpacity = ShelfLayout.surfaceShadowOpacity
        layer?.shadowRadius = ShelfLayout.surfaceShadowRadius
        layer?.shadowOffset = .zero
    }

    func animateAppearance(reduceMotion: Bool) {
        stopAppearanceAnimation()
        guard !reduceMotion, let layer else { return }

        // Animate the presentation layer only: layout and the native drop target already
        // occupy their final bounds. Compensate for AppKit's layer anchor without moving it.
        let center = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x),
                             y: layer.bounds.height * (0.5 - layer.anchorPoint.y))
        // Uniform scaling preserves the window's shape; one overshoot settles directly to 100%.
        let scales: [CGFloat] = [0.38, 1.06, 1]
        let scaleAnimation = CAKeyframeAnimation(keyPath: "transform")
        scaleAnimation.values = scales.map { scale in
            var transform = CATransform3DMakeScale(scale, scale, 1)
            transform.m41 = center.x * (1 - scale)
            transform.m42 = center.y * (1 - scale)
            return NSValue(caTransform3D: transform)
        }
        // About 280 ms to grow visibly from a small surface, then a single 140 ms settle.
        scaleAnimation.keyTimes = [0, 0.67, 1]
        scaleAnimation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        scaleAnimation.duration = 0.42

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.06
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards

        let appearance = CAAnimationGroup()
        appearance.animations = [scaleAnimation, fade]
        appearance.duration = scaleAnimation.duration
        layer.add(appearance, forKey: Self.appearanceAnimationKey)
    }

    func stopAppearanceAnimation() {
        // Model-layer geometry and opacity never change, so interruption restores them immediately.
        layer?.removeAnimation(forKey: Self.appearanceAnimationKey)
    }
}

@MainActor
final class ShelfWindowController {
    let panel: ShelfPanel
    let destination: DropDestinationView
    let dragHandle = HeaderDragView()
    private let store: ShelfStore
    private let services: ShelfServicesController
    private let dockTargets: @MainActor () -> [ShelfDockTarget]
    private(set) var dockedDisplayID: UInt32?
    private var detachedDisplayID: UInt32?
    var isDocked: Bool { dockedDisplayID != nil }
    private let glass = ShelfGlassView(frame: .zero)
    private let surface: ShelfSurfaceView
    private let quickLook: ShelfQuickLookController
    private var accessibilityObserver: NSObjectProtocol?
    private var shelfHost: NSHostingView<ShelfView>?
    private var capsuleHost: NSHostingView<ShelfCapsuleView>?
    private var shelfSizeConstraints: [NSLayoutConstraint] = []
    private var expandedFrame: CGRect?
    private var collapsedFrame: CGRect?
    private var collapseAnimation: Task<Void, Never>?
    private var collapseTarget: CGRect?
    private var expansionAnimation: Task<Void, Never>?
    private static let expansionAnimationKey = "layby.expand"
    private static let collapseAnimationKey = "layby.collapse"
    private(set) var isCollapsed = false
    var onHide: (() -> Void)?
    var onBeginMoving: (() -> Void)?
    var onCollapse: (() -> Void)?

    init(store: ShelfStore, dockTargets: @escaping @MainActor () -> [ShelfDockTarget] = { ShelfDockTarget.currentScreens() }) {
        self.store = store
        services = ShelfServicesController(store: store)
        self.dockTargets = dockTargets
        panel = ShelfPanel(contentRect: CGRect(origin: .zero, size: ShelfLayout.windowSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        quickLook = ShelfQuickLookController(store: store, shelfPanel: panel)
        panel.quickLook = quickLook
        panel.services = services
        panel.title = L10n.text("Layby 文件停放区")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // WindowServer's shadow can outline the rectangular backing surface when it becomes key.
        // Draw a rounded shadow in our transparent surface instead.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        destination = DropDestinationView(store: store)
        surface = ShelfSurfaceView(frame: CGRect(origin: .zero, size: ShelfLayout.windowSize))
        panel.contentView = surface
        glass.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(glass)
        // The drop surface stays untransformed. Its two content hosts animate
        // independently, while one native handle remains above both of them.
        destination.translatesAutoresizingMaskIntoConstraints = false
        destination.wantsLayer = true
        destination.layer?.masksToBounds = true
        surface.addSubview(destination)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: ShelfLayout.shadowInset),
            glass.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -ShelfLayout.shadowInset),
            glass.topAnchor.constraint(equalTo: surface.topAnchor, constant: ShelfLayout.shadowInset),
            glass.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -ShelfLayout.shadowInset),
            destination.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            destination.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            destination.topAnchor.constraint(equalTo: glass.topAnchor),
            destination.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        glass.onContentAppearanceChange = { [weak destination] appearance in
            destination?.appearance = appearance
        }
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        destination.addSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.centerXAnchor.constraint(equalTo: destination.centerXAnchor),
            dragHandle.topAnchor.constraint(equalTo: destination.topAnchor, constant: ShelfLayout.handleTopInset),
            dragHandle.widthAnchor.constraint(equalToConstant: ShelfLayout.handleSize.width),
            dragHandle.heightAnchor.constraint(equalToConstant: ShelfLayout.handleSize.height)
        ])
        dragHandle.onClick = { [weak self] in
            guard let self else { return }
            if self.isCollapsed { self.restore() } else { self.collapse() }
        }
        dragHandle.onBeginDragging = { [weak self] in
            self?.beginMoving()
        }
        dragHandle.onEndDragging = { [weak self] in self?.endMoving() }
        dragHandle.updateAccessibilityLabels()
        panel.onHide = { [weak self] in self?.hide() }
        // A collapsed browser retains selection, but its hidden rows must not receive edits.
        panel.onSelectAll = { [weak self] in
            guard let self, !self.isCollapsed else { return }
            self.store.selection = Set(self.store.visibleReadyItems.map(\.id))
        }
        panel.onDelete = { [weak self] in if self?.isCollapsed == false { self?.store.removeSelection() } }
        panel.onCopy = { [weak self] in if self?.isCollapsed == false { self?.store.copySelection() } }
        panel.onQuickLook = { [weak self] in
            guard let self, !self.isCollapsed else { return false }
            return self.quickLook.toggle()
        }
        panel.onNavigate = { [weak self] direction in
            guard let self, !self.isCollapsed else { return false }
            return self.store.moveSelection(direction)
        }
        panel.dismissQuickLook = { [weak self] in self?.quickLook.dismiss() ?? false }
        installShelfContent()
        updateAccessibility()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAccessibility() }
            }
    }

    private func installShelfContent() {
        guard shelfHost == nil else { return }
        let host = NSHostingView(rootView: ShelfView(store: store,
            hide: { [weak self] in self?.hide() },
            presentationChanged: { [weak self] in self?.resizeForPresentation() }))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        host.focusRingType = .none
        host.wantsLayer = true
        destination.focusRingType = .none
        destination.addSubview(host, positioned: .below, relativeTo: dragHandle)
        shelfHost = host
        // Freeze this host's size while collapsed. Keeping the same SwiftUI tree and
        // viewport preserves scroll position, folder navigation and file leases.
        let size = ShelfLayout.windowSize(for: store.presentation)
        shelfSizeConstraints = [host.widthAnchor.constraint(equalToConstant: size.width - ShelfLayout.shadowInset * 2),
                                host.heightAnchor.constraint(equalToConstant: size.height - ShelfLayout.shadowInset * 2)]
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: destination.leadingAnchor),
            host.topAnchor.constraint(equalTo: destination.topAnchor)] + shelfSizeConstraints)

        let capsule = NSHostingView(rootView: ShelfCapsuleView(store: store))
        capsule.sizingOptions = []
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.focusRingType = .none
        capsule.wantsLayer = true
        capsule.isHidden = true
        destination.addSubview(capsule, positioned: .below, relativeTo: dragHandle)
        capsuleHost = capsule
        NSLayoutConstraint.activate([capsule.centerXAnchor.constraint(equalTo: destination.centerXAnchor),
            capsule.topAnchor.constraint(equalTo: destination.topAnchor),
            capsule.widthAnchor.constraint(equalToConstant: ShelfLayout.capsuleSize.width),
            capsule.heightAnchor.constraint(equalToConstant: ShelfLayout.capsuleSize.height)])
    }

    private func setDockedDisplay(_ id: UInt32?) {
        dockedDisplayID = id
        panel.isDocked = id != nil
        dragHandle.isDocked = id != nil
    }

    private func dockedFrame(for size: CGSize) -> CGRect? {
        guard let id = dockedDisplayID else { return nil }
        guard let target = dockTargets().first(where: { $0.displayID == id }) else {
            setDockedDisplay(nil)
            return nil
        }
        return target.frame(for: size)
    }

    private func beginMoving() {
        finishExpansionAnimation()
        finishCollapseAnimation()
        surface.stopAppearanceAnimation()
        detachedDisplayID = dockedDisplayID
        if isDocked {
            setDockedDisplay(nil)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        onBeginMoving?()
    }

    private func endMoving() {
        defer { detachedDisplayID = nil }
        guard panel.isVisible,
              let target = dockTargets().first(where: {
                  $0.displayID != detachedDisplayID && $0.captures(panel.frame)
              }) else { return }
        setDockedDisplay(target.displayID)
        setFrame(target.frame(for: panel.frame.size), animated: true)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func resizeForPresentation() {
        finishExpansionAnimation()
        guard !isCollapsed, panel.isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = dockedFrame(for: ShelfLayout.windowSize(for: store.presentation))
            ?? ShelfGeometry.resizedFrame(panel.frame, size: ShelfLayout.windowSize(for: store.presentation),
                                               in: screen.visibleFrame.insetBy(dx: 12, dy: 12))
        guard frame != panel.frame else { return }
        setFrame(frame, animated: true)
    }

    private func setFrame(_ frame: CGRect, animated: Bool) {
        surface.stopAppearanceAnimation()
        if !isCollapsed {
            glass.expandedSize = CGSize(width: frame.width - ShelfLayout.shadowInset * 2,
                                        height: frame.height - ShelfLayout.shadowInset * 2)
        }
        if !isCollapsed, shelfSizeConstraints.count == 2 {
            shelfSizeConstraints[0].constant = frame.width - ShelfLayout.shadowInset * 2
            shelfSizeConstraints[1].constant = frame.height - ShelfLayout.shadowInset * 2
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            dragHandle.preserveHoverDuringLayout {
                panel.setFrame(frame, display: true)
                surface.layoutSubtreeIfNeeded()
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    func collapse(animated: Bool = true) {
        finishExpansionAnimation()
        guard panel.isVisible, !isCollapsed, !store.isDraggingOut, !store.isDropTargeted,
              !destination.isReceiving, let screen = panel.screen ?? NSScreen.main else { return }
        services.cancelServicesMenu()
        quickLook.dismiss()
        panel.makeFirstResponder(nil)
        expandedFrame = panel.frame
        let frame = dockedFrame(for: ShelfLayout.capsuleWindowSize)
            ?? ShelfGeometry.resizedFrame(panel.frame, size: ShelfLayout.capsuleWindowSize,
                                               in: screen.visibleFrame.insetBy(dx: 12, dy: 12))
        collapsedFrame = frame
        isCollapsed = true
        destination.preservesBrowsingOnDrop = true
        onCollapse?()
        collapseTarget = frame
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animateCollapse(to: frame)
        } else {
            finishCollapseAnimation()
        }
        panel.resignKey()
    }

    /// Attract both surfaces toward the same stationary handle, keeping the
    /// original viewport intact until all outgoing content has been absorbed.
    private func animateCollapse(to frame: CGRect) {
        surface.stopAppearanceAnimation()
        surface.layoutSubtreeIfNeeded()
        // Materialize AppKit's backing-layer hierarchy before converting between layers.
        CATransaction.flush()
        guard let layer = glass.layer, layer.bounds.width > 0, layer.bounds.height > 0,
              let shrink = handleTransitionAnimation(for: layer,
                finalScale: CGSize(width: ShelfLayout.capsuleSize.width / layer.bounds.width,
                                   height: ShelfLayout.capsuleSize.height / layer.bounds.height),
                fades: false) else {
            finishCollapseAnimation()
            return
        }
        destination.blocksInteraction = true
        layer.add(shrink, forKey: Self.collapseAnimationKey)
        if let contentLayer = shelfHost?.layer,
           let outgoing = handleTransitionAnimation(for: contentLayer,
                finalScale: CGSize(width: 0.005, height: 0.005), fades: true) {
            contentLayer.add(outgoing, forKey: Self.collapseAnimationKey)
        }
        // The capsule has no interior content to reveal. Keep its chrome hidden
        // until the surrounding glass reaches its final shape.
        let shadow = CABasicAnimation(keyPath: "shadowPath")
        shadow.fromValue = surface.layer?.shadowPath
        let target = CGRect(x: frame.minX - panel.frame.minX + ShelfLayout.shadowInset,
                            y: frame.minY - panel.frame.minY + ShelfLayout.shadowInset,
                            width: frame.width - ShelfLayout.shadowInset * 2,
                            height: frame.height - ShelfLayout.shadowInset * 2)
        shadow.toValue = CGPath(roundedRect: target, cornerWidth: ShelfLayout.capsuleCornerRadius,
                               cornerHeight: ShelfLayout.capsuleCornerRadius, transform: nil)
        shadow.duration = ShelfLayout.collapseDuration
        shadow.timingFunction = shrink.timingFunction
        shadow.fillMode = .forwards
        shadow.isRemovedOnCompletion = false
        surface.layer?.add(shadow, forKey: Self.collapseAnimationKey)

        collapseAnimation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ShelfLayout.collapseDuration))
            guard !Task.isCancelled else { return }
            self?.finishCollapseAnimation()
        }
    }

    private func handleTransitionAnimation(for layer: CALayer, finalScale: CGSize,
                                           fades: Bool, expanding: Bool = false) -> CAAnimationGroup? {
        guard let parent = layer.superlayer, let handleLayer = dragHandle.layer else { return nil }
        // Work in the actual parent-layer coordinate system. NSHostingView and
        // AppKit glass can use different flipped coordinates and anchor points;
        // deriving translation from view.isFlipped can send the content downward.
        let sink = parent.convert(CGPoint(x: handleLayer.bounds.midX, y: handleLayer.bounds.midY),
                                  from: handleLayer)
        let center = CGPoint(x: layer.frame.midX, y: layer.frame.midY)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: layer.position)
        position.toValue = NSValue(point: CGPoint(
            x: sink.x - (center.x - layer.position.x) * finalScale.width,
            y: sink.y - (center.y - layer.position.y) * finalScale.height))
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.toValue = NSValue(caTransform3D: CATransform3DMakeScale(finalScale.width, finalScale.height, 1))
        if expanding {
            swap(&position.fromValue, &position.toValue)
            swap(&scale.fromValue, &scale.toValue)
        }
        var animations: [CAAnimation] = [position, scale]
        if fades {
            // Fade only near the grip, keeping content legible on the outer trajectory.
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = expanding ? [0, 1, 1] : [1, 1, 0]
            opacity.keyTimes = expanding ? [0, 0.45, 1] : [0, 0.55, 1]
            animations.append(opacity)
        }
        for animation in animations { animation.duration = ShelfLayout.collapseDuration }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = ShelfLayout.collapseDuration
        // Reverse the absorption curve as well as its geometry: release quickly,
        // then settle, with identical progress for the left and right edges.
        group.timingFunction = expanding
            ? CAMediaTimingFunction(controlPoints: 0.3, 0.4, 0.6, 1)
            : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.7, 0.6)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        return group
    }

    private func finishCollapseAnimation() {
        collapseAnimation?.cancel()
        collapseAnimation = nil
        guard let frame = collapseTarget else { return }
        collapseTarget = nil
        glass.layer?.removeAnimation(forKey: Self.collapseAnimationKey)
        surface.layer?.removeAnimation(forKey: Self.collapseAnimationKey)
        shelfHost?.layer?.removeAnimation(forKey: Self.collapseAnimationKey)
        capsuleHost?.layer?.removeAnimation(forKey: Self.collapseAnimationKey)
        shelfHost?.isHidden = true
        capsuleHost?.isHidden = false
        updateCornerRadius()
        setFrame(frame, animated: false)
        surface.layoutSubtreeIfNeeded()
        destination.blocksInteraction = false
    }

    func restore(animated: Bool = true, focus: Bool = true) {
        finishExpansionAnimation()
        finishCollapseAnimation()
        guard isCollapsed, !store.isDraggingOut, !store.isDropTargeted, !destination.isReceiving,
              let screen = panel.screen ?? NSScreen.main else { return }
        let origin = expandedFrame ?? panel.frame
        let parked = collapsedFrame ?? panel.frame
        let moved = origin.offsetBy(dx: panel.frame.minX - parked.minX, dy: panel.frame.maxY - parked.maxY)
        let frame = dockedFrame(for: ShelfLayout.windowSize(for: store.presentation))
            ?? ShelfGeometry.resizedFrame(moved, size: ShelfLayout.windowSize(for: store.presentation),
                                               in: screen.visibleFrame.insetBy(dx: 12, dy: 12))
        // Prepare the backing layers before changing the viewport. Commit the
        // full-size window and its initial compressed appearance together so no
        // unanimated full-size content is shown between the two states.
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isCollapsed = false
        destination.preservesBrowsingOnDrop = false
        expandedFrame = nil
        collapsedFrame = nil
        capsuleHost?.isHidden = true
        shelfHost?.isHidden = false
        panel.makeFirstResponder(nil)
        updateCornerRadius()
        setFrame(frame, animated: false)
        surface.layoutSubtreeIfNeeded()
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animateExpansion()
        }
        CATransaction.commit()
        if focus { panel.makeKey() }
    }

    private func animateExpansion() {
        guard let layer = glass.layer, layer.bounds.width > 0, layer.bounds.height > 0,
              let release = handleTransitionAnimation(for: layer,
                finalScale: CGSize(width: ShelfLayout.capsuleSize.width / layer.bounds.width,
                                   height: ShelfLayout.capsuleSize.height / layer.bounds.height),
                fades: false, expanding: true) else { return }
        destination.blocksInteraction = true
        layer.add(release, forKey: Self.expansionAnimationKey)
        if let contentLayer = shelfHost?.layer,
           let incoming = handleTransitionAnimation(for: contentLayer,
                finalScale: CGSize(width: 0.005, height: 0.005), fades: true, expanding: true) {
            contentLayer.add(incoming, forKey: Self.expansionAnimationKey)
        }
        let compactRect = CGRect(x: surface.bounds.midX - ShelfLayout.capsuleSize.width / 2,
                                 y: surface.bounds.maxY - ShelfLayout.shadowInset - ShelfLayout.capsuleSize.height,
                                 width: ShelfLayout.capsuleSize.width, height: ShelfLayout.capsuleSize.height)
        let shadow = CABasicAnimation(keyPath: "shadowPath")
        shadow.fromValue = CGPath(roundedRect: compactRect, cornerWidth: ShelfLayout.capsuleCornerRadius,
                                  cornerHeight: ShelfLayout.capsuleCornerRadius, transform: nil)
        shadow.toValue = surface.layer?.shadowPath
        shadow.duration = ShelfLayout.collapseDuration
        shadow.timingFunction = release.timingFunction
        surface.layer?.add(shadow, forKey: Self.expansionAnimationKey)
        expansionAnimation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ShelfLayout.collapseDuration))
            guard !Task.isCancelled else { return }
            self?.finishExpansionAnimation()
        }
    }

    private func finishExpansionAnimation() {
        guard expansionAnimation != nil else { return }
        expansionAnimation?.cancel()
        expansionAnimation = nil
        glass.layer?.removeAnimation(forKey: Self.expansionAnimationKey)
        surface.layer?.removeAnimation(forKey: Self.expansionAnimationKey)
        shelfHost?.layer?.removeAnimation(forKey: Self.expansionAnimationKey)
        destination.blocksInteraction = false
    }

    private func updateCornerRadius() {
        panel.permitsFileServices = !isCollapsed
        let radius = isCollapsed ? ShelfLayout.capsuleCornerRadius : ShelfLayout.cornerRadius
        glass.isCollapsed = isCollapsed
        surface.cornerRadius = radius
        destination.layer?.cornerRadius = radius
        if dragHandle.isCollapsed != isCollapsed { dragHandle.isCollapsed = isCollapsed }
    }

    /// Count visible shelf content on each display, including capsules and a
    /// window spanning two displays; the transparent shadow is not an instance.
    func isVisible(on screenFrame: CGRect) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: ShelfLayout.shadowInset, dy: ShelfLayout.shadowInset)
            .intersects(screenFrame)
    }

    func show(near point: CGPoint, focus: Bool, notchScreen: NSScreen? = nil, expand: Bool = true) {
        finishExpansionAnimation()
        finishCollapseAnimation()
        if dockedFrame(for: panel.frame.size) != nil {
            if isCollapsed, expand { restore(animated: false, focus: focus) }
            let size = isCollapsed ? ShelfLayout.capsuleWindowSize : ShelfLayout.windowSize(for: store.presentation)
            if let frame = dockedFrame(for: size) { setFrame(frame, animated: false) }
            store.refreshReferences()
            panel.orderFrontRegardless()
            if focus { panel.makeKey() }
            return
        }
        if isCollapsed {
            if expand { restore(animated: false, focus: focus) }
            // Automatic drag activation must not move or enlarge the user's drop target.
            if isCollapsed {
                if let screen = panel.screen ?? NSScreen.main {
                    setFrame(ShelfGeometry.resizedFrame(panel.frame, size: ShelfLayout.capsuleWindowSize,
                        in: screen.visibleFrame.insetBy(dx: 12, dy: 12)), animated: false)
                }
                panel.orderFrontRegardless()
                return
            }
        }
        let wasVisible = panel.isVisible
        surface.stopAppearanceAnimation()
        installShelfContent()
        store.refreshReferences()
        let screen = notchScreen ?? NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let screen {
            let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            var frame = ShelfGeometry.frame(size: ShelfLayout.windowSize(for: store.presentation), near: point, in: bounds)
            if notchScreen != nil {
                frame.origin.x = screen.frame.midX - frame.width / 2
                frame.origin.y = screen.frame.maxY - screen.safeAreaInsets.top - frame.height - 12
                frame.origin.y = max(bounds.minY, frame.origin.y)
            }
            setFrame(frame, animated: false)
        }
        surface.layoutSubtreeIfNeeded()
        if !wasVisible {
            surface.animateAppearance(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        panel.orderFrontRegardless()
        if focus { panel.makeKey() }
    }

    func hide() {
        services.cancelServicesMenu()
        finishExpansionAnimation()
        finishCollapseAnimation()
        quickLook.dismiss()
        surface.stopAppearanceAnimation()
        panel.orderOut(nil)
        setDockedDisplay(nil)
        detachedDisplayID = nil
        panel.makeFirstResponder(nil)
        isCollapsed = false
        destination.preservesBrowsingOnDrop = false
        expandedFrame = nil
        collapsedFrame = nil
        updateCornerRadius()
        glass.resetContentAppearance()
        store.clear()
        // Hidden SwiftUI rows can retain item snapshots and their file leases. Tear them
        // down now; the next presentation builds fresh content from the empty store.
        dragHandle.stopTrackingDrag()
        shelfHost?.removeFromSuperview()
        capsuleHost?.removeFromSuperview()
        shelfHost = nil
        capsuleHost = nil
        shelfSizeConstraints.removeAll()
        onHide?()
    }
    func stop() {
        hide()
        quickLook.stop()
        services.stop()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    private func updateAccessibility() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            surface.stopAppearanceAnimation()
            finishExpansionAnimation()
            finishCollapseAnimation()
        }
        destination.wantsLayer = true
        glass.refreshAccessibilityBackground()
        destination.layer?.backgroundColor = NSColor.clear.cgColor
        dragHandle.updateAccessibilityLabels()
        updateCornerRadius()
    }
}
