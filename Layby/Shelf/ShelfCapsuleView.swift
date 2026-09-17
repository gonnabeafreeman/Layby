import SwiftUI

enum ShelfSideEdge {
    case left
    case right
}

/// Only the capsule surface remains; the window owns its persistent drag handle.
struct ShelfCapsuleView: View {
    @Bindable var store: ShelfStore

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                ShelfDropBorder(isTargeted: store.isDropTargeted, cornerRadius: ShelfLayout.capsuleCornerRadius)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The slim, visible part of a shelf that has been tucked beyond a screen edge.
struct ShelfSideTabView: View {
    let edge: ShelfSideEdge
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if edge == .right { restoreButton }
            Spacer(minLength: 0)
            if edge == .left { restoreButton }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: restore)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("展开停放区"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.text("展开停放区")), restore)
    }

    private var restoreButton: some View {
        ShelfSideChevron(pointsRight: edge == .left)
            .stroke(Color(nsColor: .tertiaryLabelColor),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            .frame(width: 12, height: 50)
            .frame(width: ShelfLayout.sideRevealWidth)
            .frame(maxHeight: .infinity)
    }
}

/// A deliberately broad, rounded chevron keeps the small side tab easy to spot.
private struct ShelfSideChevron: Shape {
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.24
        let outerX = pointsRight ? rect.minX + inset : rect.maxX - inset
        let tipX = pointsRight ? rect.maxX - inset : rect.minX + inset
        var path = Path()
        path.move(to: CGPoint(x: outerX, y: rect.minY + 8))
        path.addLine(to: CGPoint(x: tipX, y: rect.midY))
        path.addLine(to: CGPoint(x: outerX, y: rect.maxY - 8))
        return path
    }
}
