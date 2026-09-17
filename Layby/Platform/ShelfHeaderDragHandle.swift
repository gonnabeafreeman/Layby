import AppKit
import QuartzCore

enum ShelfLayout {
    static let size = CGSize(width: 200, height: 220)
    static let expandedSize = CGSize(width: 500, height: 360)
    static let capsuleSize = CGSize(width: 108, height: 20)
    static let capsuleCornerRadius: CGFloat = 10
    static let collapseDuration: TimeInterval = 0.28
    /// The transparent margin around the shelf also gives its shadow room to fade naturally.
    static let surfaceShadowOpacity: Float = 0.18
    static let surfaceShadowRadius: CGFloat = 6
    static let capsuleWindowSize = CGSize(width: capsuleSize.width + shadowInset * 2,
                                         height: capsuleSize.height + shadowInset * 2)
    static let cornerRadius: CGFloat = 26
    static let headerButtonSize: CGFloat = 25
    static let handleSize = CGSize(width: 100, height: 16)
    static let handleTopInset: CGFloat = 2
    static let sideRevealWidth: CGFloat = 30
    // The empty-state container begins below the header while the shelf has a
    // smaller bottom inset. Offset its label by half that difference so it is
    // centered in the whole shelf rather than only in the remaining area.
    static var emptyStateVerticalOffset: CGFloat {
        (headerButtonInset + headerButtonSize + 8 - 12) / 2
    }
    static let gridMinimumItemWidth: CGFloat = 128
    static let gridColumnSpacing: CGFloat = 10
    static func gridColumns(for width: CGFloat) -> Int {
        max(1, Int((width + gridColumnSpacing) / (gridMinimumItemWidth + gridColumnSpacing)))
    }
    // Match the button centers to the corner centers, with equal top and side insets.
    static var headerButtonInset: CGFloat { max(0, cornerRadius - headerButtonSize / 2) }
    static let shadowInset: CGFloat = 20
    static let windowSize = CGSize(width: size.width + shadowInset * 2, height: size.height + shadowInset * 2)
    static func windowSize(for presentation: ShelfPresentation) -> CGSize {
        let content = presentation.isExpanded ? expandedSize : size
        return CGSize(width: content.width + shadowInset * 2, height: content.height + shadowInset * 2)
    }
}

/// One persistent native handle, mounted above the panel's animated content.
@MainActor
final class HeaderDragView: NSView {
    var onBeginDragging: (() -> Void)?
    var onEndDragging: (() -> Void)?
    var onDragging: (() -> Void)?
    var isDocked = false { didSet { updateAccessibilityLabels() } }
    var onClick: (() -> Void)?
    private let grip = CALayer()
    private var hoverArea: NSTrackingArea?
    private var dragEndTimer: Timer?
    private var hoverReconciliation: Task<Void, Never>?
    private var isPreservingHover = false
    private var isHovered = false
    private var isDraggingWindow = false
    var isCollapsed = false { didSet { updateAccessibilityLabels() } }
    private var mouseDownEvent: NSEvent?
    private var exceededDragThreshold = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        grip.bounds = CGRect(x: 0, y: 0, width: 80, height: 4)
        // A radius equal to half the height makes each end a true semicircle.
        grip.cornerRadius = 2
        layer?.addSublayer(grip)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibilityLabels()
        updateGrip(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateAccessibilityLabels() {
        setAccessibilityRole(onClick == nil ? .group : .button)
        setAccessibilityLabel(L10n.text(onClick == nil ? "移动停放区" : (isCollapsed ? "展开停放区" : "收起为迷你胶囊")))
        let help = isDocked ? "已固定在屏幕顶部中央；单击切换大小，用力拖离可解除固定"
            : (isCollapsed ? "单击展开停放区，拖动可移动胶囊" : "单击收起为胶囊，拖动可移动停放区")
        setAccessibilityHelp(L10n.text(help))
        toolTip = L10n.text(help)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { onClick != nil }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if onClick != nil, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           event.keyCode == 36 || event.keyCode == 49 {
            if !event.isARepeat { onClick?() }
            return
        }
        super.keyDown(with: event)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grip.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect follows layout automatically. Replacing the area emits
        // artificial exit/enter events when the window changes size.
        if hoverArea == nil {
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            hoverArea = area
            addTrackingArea(area)
        }
        if !isPreservingHover { reconcileHoverAfterLayout() }
    }

    /// AppKit can query tracking between the window-origin and view-layout
    /// updates. Keep the current grip through that intermediate geometry.
    func preserveHoverDuringLayout(_ update: () -> Void) {
        hoverReconciliation?.cancel()
        isPreservingHover = true
        update()
        reconcileHoverAfterLayout()
    }

    private func reconcileHoverAfterLayout() {
        hoverReconciliation?.cancel()
        hoverReconciliation = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.hoverReconciliation = nil
            self.isPreservingHover = false
            self.refreshHover(animated: true)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hoverReconciliation?.cancel()
            hoverReconciliation = nil
            isPreservingHover = false
            stopTrackingDrag()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGrip(animated: false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        refreshHover(animated: true)
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        refreshHover(animated: true)
        if !isDraggingWindow { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        exceededDragThreshold = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initial = mouseDownEvent, !isDraggingWindow else { return }
        let distance = hypot(event.locationInWindow.x - initial.locationInWindow.x,
                             event.locationInWindow.y - initial.locationInWindow.y)
        guard distance >= 4 else { return }
        // Once crossed, the gesture stays a drag even if the pointer returns to its start.
        exceededDragThreshold = true
        // Resist small pulls while docked, without treating an unsuccessful pull
        // as a click. The original press still starts the eventual native drag.
        guard distance >= (isDocked ? ShelfDockTarget.releaseDistance : 4), let window else { return }
        onBeginDragging?()
        isDraggingWindow = true
        updateGrip(animated: true)
        NSCursor.arrow.set()

        // Window Server handles the original press, including holds, screen edges and Spaces.
        // performDrag returns immediately and may consume mouseUp, so watch release only while moving.
        dragEndTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onDragging?()
                if NSEvent.pressedMouseButtons & 1 == 0 || self.window?.isVisible != true {
                    self.stopTrackingDrag(completed: self.window?.isVisible == true)
                }
            }
        }
        dragEndTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        window.performDrag(with: initial)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldClick = mouseDownEvent != nil && !exceededDragThreshold &&
            bounds.contains(convert(event.locationInWindow, from: nil))
        stopTrackingDrag(completed: true)
        guard shouldClick else { return }
        onClick?()
    }

    func stopTrackingDrag(completed: Bool = false) {
        dragEndTimer?.invalidate()
        dragEndTimer = nil
        mouseDownEvent = nil
        exceededDragThreshold = false
        guard isDraggingWindow else { return }
        isDraggingWindow = false
        refreshHover(animated: true)
        NSCursor.arrow.set()
        if completed { onEndDragging?() }
    }

    private func refreshHover(animated: Bool) {
        guard !isPreservingHover else { return }
        // Queued enter/exit events can refer to pre-resize coordinates. Use the
        // current pointer position after layout instead of trusting their type.
        isHovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateGrip(animated: animated)
    }

    private func updateGrip(animated: Bool) {
        let expanded = isHovered || isDraggingWindow
        let width: CGFloat = expanded ? 80 : 80 * 0.32
        let opacity: Float = isDraggingWindow ? 1 : (expanded ? 0.9 : 0.72)
        // A tracking refresh must not cancel or restart an unchanged hover.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Keep the idle grip legible too: charcoal on light glass, pale gray on dark glass.
        grip.backgroundColor = NSColor(white: isDark ? 0.9 : 0.22, alpha: 1).cgColor
        CATransaction.commit()
        guard grip.bounds.width != width || grip.opacity != opacity else { return }
        let currentWidth = grip.presentation()?.bounds.width ?? grip.bounds.width
        let currentOpacity = grip.presentation()?.opacity ?? grip.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grip.bounds.size.width = width
        grip.opacity = opacity
        CATransaction.commit()
        grip.removeAnimation(forKey: "hover")
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let stretch = CABasicAnimation(keyPath: "bounds.size.width")
        stretch.fromValue = currentWidth
        stretch.toValue = width
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity
        fade.toValue = opacity
        let group = CAAnimationGroup()
        group.animations = [stretch, fade]
        group.duration = expanded ? 0.18 : 0.14
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.25, 1)
        grip.add(group, forKey: "hover")
    }
}
