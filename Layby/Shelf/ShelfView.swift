import SwiftUI
import AppKit

struct ShelfView: View {
    @Bindable var store: ShelfStore
    let hide: () -> Void
    let presentationChanged: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.48, green: 0.9, blue: 0.8) : Color(red: 0.08, green: 0.43, blue: 0.4)
    }
    private var countLabel: String { L10n.fileCount(store.items.count) }
    private var summary: String {
        if let selectionSummary = store.selectionSummary { return selectionSummary }
        if store.folderBrowser.isLoading { return L10n.text("正在读取文件夹…") }
        let visible = store.visibleItems
        let pending = visible.filter { $0.state == .loading }.count
        if pending > 0 { return L10n.format("正在接收 %d 个文件…", pending) }
        let unavailable = visible.filter { !$0.state.isReady }.count
        if unavailable > 0 { return L10n.format("%d 个文件不可用", unavailable) }
        let sizes = visible.compactMap(\.byteCount)
        if sizes.count == visible.count, !sizes.isEmpty {
            let size = ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
            return store.isBrowsingFolder ? "\(L10n.fileCount(visible.count)) · \(size)" : size
        }
        if store.isBrowsingFolder { return L10n.fileCount(visible.count) }
        return L10n.text("拖动单个文件以取出")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if store.isBrowsingFolder && (store.folderBrowser.isLoading || store.folderBrowser.error != nil || store.visibleItems.isEmpty) {
                    folderStatus
                }
                else if store.items.isEmpty { emptyState }
                else if store.presentation == .stack { stack }
                else { browser }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .background {
                if store.presentation.isExpanded {
                    ShelfSelectionBackground(store: store).allowsHitTesting(false)
                }
            }
            if let notice = store.notice {
                Text(L10n.text(notice)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 12).padding(.top, 6).accessibilityLabel(L10n.text(notice))
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            ShelfDropBorder(isTargeted: store.isDropTargeted)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .tint(accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.presentation)
        .onChange(of: store.presentation) { _, _ in presentationChanged() }
    }

    private var header: some View {
        headerControls
            .frame(height: ShelfLayout.headerButtonSize)
            .padding(.horizontal, ShelfLayout.headerButtonInset)
            .padding(.top, ShelfLayout.headerButtonInset)
            .padding(.bottom, 8)
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            if store.presentation.isExpanded {
                roundButton("chevron.left", label: store.isBrowsingFolder ? "返回上一层" : "返回文件堆叠") { store.goBack() }
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.folderBrowser.directory?.displayName ?? countLabel)
                        .font(.system(size: 14, weight: .semibold)).truncationMode(.middle)
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .lineLimit(1)
                .layoutPriority(1)
            } else {
                roundButton("xmark", label: "关闭并清空停放区") { hide() }
            }
            Spacer(minLength: 8)
            if store.presentation.isExpanded {
                HStack(spacing: 4) {
                    layoutButton("square.grid.2x2", label: "缩略图网格", mode: .grid)
                    layoutButton("list.bullet", label: "文件列表", mode: .list)
                }
                roundButton("xmark", label: "关闭并清空停放区") { hide() }
            } else {
                ShelfServicesButton(enabled: !store.dragItems(for: .all).isEmpty)
                    .frame(width: ShelfLayout.headerButtonSize, height: ShelfLayout.headerButtonSize)
            }
        }
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: ShelfLayout.headerButtonSize, height: ShelfLayout.headerButtonSize)
        }
        .buttonStyle(ShelfSolidButtonStyle()).help(L10n.text(label)).accessibilityLabel(L10n.text(label))
    }

    private func layoutButton(_ symbol: String, label: String, mode: ShelfPresentation) -> some View {
        Button { store.present(mode) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(ShelfSolidButtonStyle(selected: store.presentation == mode)).help(L10n.text(label)).accessibilityLabel(L10n.text(label))
        .accessibilityAddTraits(store.presentation == mode ? .isSelected : [])
    }

    private var emptyState: some View {
        Text(L10n.text(store.isDropTargeted ? "松手，放在这里" : "拖入文件或文件夹"))
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -ShelfLayout.emptyStateVerticalOffset)
    }

    private var folderStatus: some View {
        VStack(spacing: 10) {
            if store.folderBrowser.isLoading {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在读取文件夹…"))
            } else if let error = store.folderBrowser.error {
                Text(L10n.text(error)).multilineTextAlignment(.center)
                Button(L10n.text("重新检查")) { store.reloadFolder() }
                    .buttonStyle(ShelfSolidButtonStyle()).padding(8)
            } else {
                Text(L10n.text("此文件夹为空"))
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stack: some View {
        VStack(spacing: 8) {
            DraggableFileView(store: store, scope: .all) {
                FileStackContent(items: Array(store.items.suffix(5)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help(L10n.text(store.dragItems(for: .all).isEmpty ? "接收完成后可整体拖出；可展开列表处理不可用文件" : "拖动堆叠，取出全部文件"))
            .accessibilityLabel(L10n.format("文件堆叠，%@，拖动以取出全部文件", countLabel))
            .onAppear { requestStackThumbnails() }
            .onChange(of: store.readyItems.map(\.id)) { _, _ in requestStackThumbnails() }
            .onChange(of: store.items.map(\.id)) { _, _ in requestStackThumbnails() }
            if store.readyItems.count != store.items.count {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { store.present(.grid) } label: {
                HStack(spacing: 7) {
                    Text(countLabel).font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13).frame(height: 32)
            }
            .buttonStyle(ShelfSolidButtonStyle()).help(L10n.text("展开，查看和拖出单个文件"))
            .accessibilityLabel(L10n.format("查看全部 %@", countLabel))
            .padding(.bottom, 4)
        }
    }

    private func requestStackThumbnails() {
        for item in store.items.suffix(5) { store.requestThumbnail(item.id) }
    }

    private var browser: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.presentation == .grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: ShelfLayout.gridMinimumItemWidth),
                                                spacing: ShelfLayout.gridColumnSpacing)], spacing: 12) {
                        ForEach(store.visibleItems) { item in
                            fileCell(item, grid: true)
                        }
                    }
                    .onGeometryChange(for: Int.self) { geometry in
                        ShelfLayout.gridColumns(for: geometry.size.width)
                    } action: { columns in
                        store.gridColumnCount = columns
                    }
                    .padding(.top, 8).padding(.bottom, 12)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(store.visibleItems) { item in
                            fileCell(item, grid: false)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollIndicators(.automatic)
            .onChange(of: store.selection, initial: true) { _, selection in
                guard selection.count == 1, let id = selection.first else { return }
                // No animation: held arrow keys should keep the focused row visible
                // immediately, even when Quick Look is the key window.
                proxy.scrollTo(id)
            }
        }
        .id(store.folderBrowser.directory?.id)
    }

    private func fileCell(_ item: ShelfItem, grid: Bool) -> some View {
        DraggableFileView(store: store, scope: .item(item.id)) {
            Group {
                if grid { FileTileContent(item: item) }
                else { FileRowContent(item: item) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(store.selection.contains(item.id) ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear,
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .frame(height: grid ? 146 : 54)
        .id(item.id)
        .accessibilityLabel(L10n.format("%@，%@，拖动以取出此文件", item.displayName, item.displaySubtitle))
        .help(item.displayName)
        .onAppear { store.requestThumbnail(item.id) }
        .onChange(of: item.state) { _, _ in store.requestThumbnail(item.id) }
    }
}

/// Only the blue outline animates; the glass and file contents retain their appearance.
struct ShelfDropBorder: View {
    let isTargeted: Bool
    var cornerRadius: CGFloat = ShelfLayout.cornerRadius
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var blueOutline: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(Color(nsColor: .systemBlue), lineWidth: 5)
    }

    var body: some View {
        ZStack {
            if isTargeted {
                Group {
                    if reduceMotion {
                        blueOutline.opacity(0.9)
                    } else {
                        blueOutline.phaseAnimator([0.5, 1.0]) { outline, opacity in
                            outline.opacity(opacity)
                        } animation: { _ in
                            .easeInOut(duration: 0.9)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        // Removing the targeted outline also tears down its repeating phase animation.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isTargeted)
    }
}

/// Opaque fills keep controls legible over glass; hover changes tone without changing the hit area.
struct ShelfSolidButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ShelfSolidButtonContent(label: configuration.label, pressed: configuration.isPressed, selected: selected)
    }
}

private struct ShelfSolidButtonContent<Label: View>: View {
    let label: Label
    let pressed: Bool
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Store the DynamicProperty directly so CLT builds do not require the SDK 27 State macro plugin.
    private var hoverState = State(initialValue: false)
    private var hovered: Bool { hoverState.wrappedValue }

    init(label: Label, pressed: Bool, selected: Bool) {
        self.label = label
        self.pressed = pressed
        self.selected = selected
    }

    private var fill: Color {
        let dark = colorScheme == .dark
        let white: Double
        if !isEnabled { white = dark ? 0.20 : 0.93 }
        else if pressed { white = dark ? 0.19 : 0.73 }
        else if hovered { white = dark ? (selected ? 0.43 : 0.36) : (selected ? 0.72 : 0.82) }
        else if selected { white = dark ? 0.35 : 0.79 }
        else { white = dark ? 0.27 : 0.90 }
        return Color(white: white)
    }

    var body: some View {
        label
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.9 : 0.35))
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .onHover { hoverState.wrappedValue = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

private struct FileStackContent: View {
    let items: [ShelfItem]
    private let angles: [Double] = [-16, 12, -9, 6, 0]
    private let offsets: [CGFloat] = [-18, 17, -10, 9, 0]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let depth = index + 5 - items.count
                    Image(nsImage: item.icon).resizable().scaledToFit()
                        .frame(width: 128, height: 158)
                        .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
                        .rotationEffect(.degrees(angles[depth]))
                        .offset(x: offsets[depth], y: CGFloat(items.count - index - 1) * -2)
                }
            }
            .frame(width: 220, height: 195)
            .scaleEffect(min(1, max(0, min(geometry.size.width / 220, geometry.size.height / 195))))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .accessibilityHidden(true)
    }
}

private struct FileStatus: View {
    let item: ShelfItem
    var body: some View {
        if item.state == .loading {
            ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在接收"))
        } else if case .unavailable = item.state {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel(L10n.text("文件不可用"))
        }
    }
}

private struct FileTileContent: View {
    let item: ShelfItem
    var body: some View {
        VStack(spacing: 7) {
            Image(nsImage: item.icon).resizable().scaledToFit()
                .frame(width: 104, height: 88)
                .shadow(color: .black.opacity(0.13), radius: 3, y: 2)
                .overlay(alignment: .bottomTrailing) { FileStatus(item: item) }
            Text(item.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(item.displaySubtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
    }
}

private struct FileRowContent: View {
    let item: ShelfItem
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: item.icon).resizable().scaledToFit().frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.displaySubtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            FileStatus(item: item)
        }
        .padding(.horizontal, 12)
    }
}
