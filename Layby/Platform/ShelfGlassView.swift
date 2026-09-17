import AppKit

/// Separate native renderers let only the capsule adapt to its backdrop.
/// Expanded glass retains the last visible capsule appearance.
@MainActor
final class ShelfGlassView: NSView {
    let expandedContent = ShelfGlassContentView(frame: .zero)
    let capsuleContent = ShelfGlassContentView(frame: .zero)
    let expandedEffect: NSView
    let capsuleEffect: NSView
    var onContentAppearanceChange: ((NSAppearance?) -> Void)? {
        didSet { refreshContentAppearance() }
    }
    private var retainedAppearance: NSAppearance?
    var expandedSize = ShelfLayout.size { didSet { needsLayout = true } }
    var isCollapsed = false {
        didSet {
            expandedEffect.isHidden = isCollapsed
            capsuleEffect.isHidden = !isCollapsed
            layer?.cornerRadius = isCollapsed ? ShelfLayout.capsuleCornerRadius : ShelfLayout.cornerRadius
            needsLayout = true
            refreshContentAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        expandedEffect = Self.makeEffect(content: expandedContent, radius: ShelfLayout.cornerRadius)
        capsuleEffect = Self.makeEffect(content: capsuleContent, radius: ShelfLayout.capsuleCornerRadius)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ShelfLayout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        focusRingType = .none
        addSubview(expandedEffect)
        addSubview(capsuleEffect)
        capsuleEffect.isHidden = true
        capsuleContent.onAppearanceChange = { [weak self] _ in self?.refreshContentAppearance() }
        updateBorderAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeEffect(content: NSView, radius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .regular
            effect.cornerRadius = radius
            effect.contentView = content
            return effect
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        return effect
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        expandedEffect.frame = CGRect(x: 0, y: bounds.maxY - expandedSize.height,
                                      width: expandedSize.width, height: expandedSize.height)
        capsuleEffect.frame = CGRect(x: bounds.midX - ShelfLayout.capsuleSize.width / 2,
                                     y: bounds.maxY - ShelfLayout.capsuleSize.height,
                                     width: ShelfLayout.capsuleSize.width, height: ShelfLayout.capsuleSize.height)
        CATransaction.commit()
    }

    func refreshAccessibilityBackground() {
        expandedContent.refreshAppearance()
        capsuleContent.refreshAppearance()
        refreshContentAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderAppearance()
        refreshContentAppearance()
    }

    func resetContentAppearance() {
        retainedAppearance = nil
        refreshContentAppearance()
    }

    private func refreshContentAppearance() {
        if #available(macOS 26.0, *), isCollapsed,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            // Snapshot the theme, rather than retaining the native adaptive appearance.
            let name = capsuleContent.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
            retainedAppearance = NSAppearance(named: name)
        }
        let contentAppearance = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? effectiveAppearance : (retainedAppearance ?? effectiveAppearance)
        // Never override the capsule renderer: native glass must remain free to adapt.
        expandedEffect.appearance = contentAppearance
        expandedContent.appearance = contentAppearance
        onContentAppearanceChange?(contentAppearance)
    }

    /// A restrained adaptive outline separates translucent glass from similar
    /// backdrops, while the surface view provides the outer elevation.
    private func updateBorderAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.borderColor = NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.28 : 0.18).cgColor
        }
    }
}
