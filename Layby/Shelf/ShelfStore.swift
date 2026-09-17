import AppKit
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers
import os

enum ShelfItemState: Equatable {
    case loading, ready, unavailable(String)
    var isReady: Bool { self == .ready }
}

enum ShelfPresentation {
    case stack, grid, list
    var isExpanded: Bool { self != .stack }
}

enum ShelfDragScope {
    case all
    case item(UUID)
}

enum ShelfNavigationDirection {
    case left, right, up, down
}

struct ShelfItem: Identifiable {
    let id: UUID
    var url: URL?
    var name: String
    var subtitle: String
    var state: ShelfItemState
    var icon: NSImage
    var identity: String?
    var byteCount: Int64?
    var isDirectory = false
    var isManaged = false
    var lease: FileAccessLease?
    @MainActor var displayName: String { url == nil ? L10n.text(name) : name }
    @MainActor var displaySubtitle: String { L10n.text(subtitle) }
}

@Observable @MainActor
final class ShelfStore {
    private(set) var items: [ShelfItem] = [] { didSet { onPreviewChange?() } }
    var selection: Set<UUID> = [] {
        didSet {
            if selection.isEmpty { selectionAnchor = nil }
            onPreviewChange?()
        }
    }
    var isDropTargeted = false
    var isDraggingOut = false
    var notice: String?
    private(set) var presentation: ShelfPresentation = .stack { didSet { onPreviewChange?() } }
    let folderBrowser = ShelfFolderBrowser()
    var gridColumnCount = 1
    @ObservationIgnored var onPreviewChange: (() -> Void)?
    @ObservationIgnored private var selectionAnchor: UUID?
    @ObservationIgnored let managedFiles: ManagedFileStore
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var imports: [UUID: NSFilePromiseReceiver] = [:]
    @ObservationIgnored private var importTimeouts: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var thumbnails: [UUID: QLThumbnailGenerator.Request] = [:]
    @ObservationIgnored private var receivedSequences: [Int] = []
    @ObservationIgnored private let inspectionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(managedFiles: ManagedFileStore = ManagedFileStore()) {
        self.managedFiles = managedFiles
        folderBrowser.onChange = { [weak self] in self?.onPreviewChange?() }
    }

    var readyItems: [ShelfItem] { items.filter { $0.state.isReady } }
    var isBrowsingFolder: Bool { folderBrowser.directory != nil }
    var visibleItems: [ShelfItem] { isBrowsingFolder ? folderBrowser.items : items }
    var visibleReadyItems: [ShelfItem] { visibleItems.filter { $0.state.isReady } }
    var selectedItems: [ShelfItem] { visibleReadyItems.filter { selection.contains($0.id) } }
    var previewItems: [ShelfItem] { presentation.isExpanded ? selectedItems : [] }
    var exportItems: [ShelfItem] { selection.isEmpty ? visibleReadyItems : selectedItems }

    var selectionSummary: String? {
        let selected = visibleItems.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        let sizes = selected.compactMap(\.byteCount)
        let size = sizes.count == selected.count
            ? ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
            : L10n.text("大小未知")
        return L10n.format("已选择 %d 个文件 · %@", selected.count, size)
    }

    func clearSelection() { selection.removeAll() }

    /// Return true at boundaries as well, so a handled arrow never becomes an
    /// invalid-input beep. Multi-selection and the stack keep their own behavior.
    @discardableResult func moveSelection(_ direction: ShelfNavigationDirection, skippingUnavailable: Bool = false) -> Bool {
        let entries = visibleItems
        guard presentation.isExpanded, selection.count == 1, let id = selection.first,
              var index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let columns = presentation == .grid ? max(1, gridColumnCount) : 1
        func nextIndex(after current: Int) -> Int? {
            switch direction {
            case .left: return current > 0 ? current - 1 : nil
            case .right: return current + 1 < entries.count ? current + 1 : nil
            case .up: return current >= columns ? current - columns : nil
            case .down:
                guard current / columns < (entries.count - 1) / columns else { return nil }
                return min(current + columns, entries.count - 1)
            }
        }
        while let next = nextIndex(after: index) {
            if !skippingUnavailable || entries[next].state.isReady {
                select(entries[next].id, extending: false)
                return true
            }
            index = next
        }
        return true
    }

    func present(_ presentation: ShelfPresentation) {
        if presentation == .stack { resetFolderBrowsing() }
        self.presentation = items.isEmpty ? .stack : presentation
        selection.removeAll()
    }

    /// Dragging a selected card exports the selection in display order. An
    /// unselected card exports itself; incomplete groups never export partially.
    func dragItems(for scope: ShelfDragScope) -> [ShelfItem] {
        switch scope {
        case .all: return !items.isEmpty && items.allSatisfy({ $0.state.isReady }) ? items : []
        case .item(let id):
            guard let item = visibleItems.first(where: { $0.id == id }), item.state.isReady else { return [] }
            guard selection.contains(id) else { return [item] }
            let selected = visibleItems.filter { selection.contains($0.id) }
            return selected.allSatisfy({ $0.state.isReady }) ? selected : []
        }
    }

    func select(_ id: UUID, extending: Bool, range: Bool = false) {
        let items = visibleItems
        guard let end = items.firstIndex(where: { $0.id == id }) else { return }
        if range {
            let anchor = selectionAnchor ?? items.first(where: { selection.contains($0.id) })?.id ?? id
            let start = items.firstIndex(where: { $0.id == anchor }) ?? end
            let ids = Set(items[min(start, end)...max(start, end)].map(\.id))
            selectionAnchor = items[start].id
            selection = extending ? selection.union(ids) : ids
            return
        }
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else { selection = [id] }
        selectionAnchor = selection.contains(id) ? id : items.first(where: { selection.contains($0.id) })?.id
    }

    func remove(_ ids: Set<UUID>) {
        if folderBrowser.containsRoot(ids) { resetFolderBrowsing() }
        for id in ids {
            if let request = thumbnails.removeValue(forKey: id) { QLThumbnailGenerator.shared.cancel(request) }
            imports.removeValue(forKey: id)
            importTimeouts.removeValue(forKey: id)?.cancel()
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let selectionAnchor, ids.contains(selectionAnchor) { self.selectionAnchor = nil }
        if items.isEmpty { presentation = .stack }
    }

    func clear() {
        generation = UUID()
        resetFolderBrowsing()
        remove(Set(items.map(\.id)))
        importTimeouts.values.forEach { $0.cancel() }
        importTimeouts.removeAll()
        imports.removeAll()
        selection.removeAll()
        isDropTargeted = false
        notice = nil
        presentation = .stack
    }

    /// Called exclusively by a real drop callback. Owned promise files carry their directory lease.
    @discardableResult func add(_ urls: [URL], managedDirectory: ManagedFileDirectory? = nil) -> Int {
        var added = 0
        for url in urls where url.isFileURL {
            guard !items.contains(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) else { continue }
            let id = UUID()
            let lease = FileAccessLease(url: url, managedDirectory: managedDirectory)
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            items.append(ShelfItem(id: id, url: url, name: url.lastPathComponent, subtitle: "正在读取…",
                                   state: .loading, icon: NSWorkspace.shared.icon(for: type), isManaged: managedDirectory != nil, lease: lease))
            inspect(id: id, lease: lease, generation: generation)
            added += 1
        }
        return added
    }

    func retry(_ id: UUID) {
        if isBrowsingFolder, visibleItems.contains(where: { $0.id == id }) { reloadFolder(); return }
        guard let index = items.firstIndex(where: { $0.id == id }), let lease = items[index].lease else { return }
        items[index].state = .loading
        inspect(id: id, lease: lease, generation: generation)
    }

    func refreshReferences() {
        for item in items where item.state.isReady {
            if let lease = item.lease { inspect(id: item.id, lease: lease, generation: generation) }
        }
    }

    @discardableResult func receive(_ info: NSDraggingInfo, preservingBrowsing: Bool = false) -> Bool {
        let sequence = info.draggingSequenceNumber
        if receivedSequences.contains(sequence) { return true }
        guard info.draggingSourceOperationMask.contains(.copy), !isDraggingOut else { return false }
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self, NSFilePromiseReceiver.self],
            options: [.urlReadingFileURLsOnly: true]) ?? []
        let urls = objects.compactMap { $0 as? URL }.filter(\.isFileURL)
        let promises = objects.compactMap { $0 as? NSFilePromiseReceiver }
        guard !urls.isEmpty || !promises.isEmpty else { return false }
        // A shelf drop always parks files at the root; it never writes into a
        // directory merely because the user happens to be browsing it.
        // Capsule drops still append at the shelf root, without disturbing the
        // hidden browser's current directory or selection.
        if !preservingBrowsing { resetFolderBrowsing() }
        _ = add(urls)
        let acceptedPromises = promises.map { receivePromise($0) }.filter { $0 }.count
        guard !urls.isEmpty || acceptedPromises > 0 else { return false }
        receivedSequences.append(sequence)
        if receivedSequences.count > 64 { receivedSequences.removeFirst() }
        let total = info.draggingPasteboard.pasteboardItems?.count ?? objects.count
        notice = total > objects.count ? "已加入支持的文件，其他内容已跳过。" : nil
        return true
    }

    func copySelection() {
        let urls = exportItems.compactMap(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        notice = L10n.format("已复制 %d 个文件", urls.count)
    }

    private func inspect(id: UUID, lease: FileAccessLease, generation expected: UUID) {
        Task { [weak self] in
            guard let queue = self?.inspectionQueue else { return }
            let result: Result<FileMetadata, Error> = await withCheckedContinuation { continuation in
                queue.addOperation { continuation.resume(returning: Result { try FileMetadata.read(lease.url) }) }
            }
            guard let self, self.generation == expected,
                  let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let metadata):
                if self.items.contains(where: { $0.id != id && $0.identity == metadata.identity }) {
                    self.remove([id]); return
                }
                self.items[index].identity = metadata.identity
                self.items[index].byteCount = metadata.byteCount
                self.items[index].subtitle = metadata.subtitle
                self.items[index].isDirectory = metadata.isDirectory
                self.items[index].state = .ready
                if metadata.isDirectory { self.items[index].icon = NSWorkspace.shared.icon(for: .folder) }
            case .failure(let error):
                self.items[index].state = .unavailable("文件不可用，请检查原文件或重新拖入")
                self.items[index].subtitle = "无法访问"
                Logger.files.error("File metadata failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// SwiftUI requests previews for visible rows only; the model retains no unbounded global cache.
    func requestThumbnail(_ id: UUID) {
        guard thumbnails[id] == nil, let item = (items + folderBrowser.items).first(where: { $0.id == id }),
              item.state.isReady, !item.isDirectory, let lease = item.lease else { return }
        let request = QLThumbnailGenerator.Request(fileAt: lease.url, size: CGSize(width: 256, height: 256),
                                                  scale: 2, representationTypes: .all)
        // Ask the system for a file icon, including its native document shape,
        // transparent margins and decorations, rather than a raw content preview.
        request.iconMode = true
        thumbnails[id] = request
        let expected = generation
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, lease] representation, _ in
            _ = lease
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, let representation else { return }
                if let index = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[index].icon = representation.nsImage
                } else { self.folderBrowser.updateThumbnail(id, image: representation.nsImage) }
            }
        }
    }

    func openFolder(_ id: UUID) {
        guard presentation.isExpanded, let directory = visibleItems.first(where: { $0.id == id }),
              directory.isDirectory, directory.state.isReady, directory.lease != nil else { return }
        cancelFolderThumbnails()
        clearSelection()
        notice = nil
        folderBrowser.enter(directory)
    }

    func goBack() {
        guard let directory = folderBrowser.directory else { present(.stack); return }
        cancelFolderThumbnails()
        clearSelection()
        folderBrowser.back()
        if visibleItems.contains(where: { $0.id == directory.id }) { select(directory.id, extending: false) }
    }

    func reloadFolder() {
        cancelFolderThumbnails()
        clearSelection()
        folderBrowser.reload()
    }

    func removeSelection() {
        // Child rows are a directory listing, not independently parked items.
        guard !isBrowsingFolder else { return }
        remove(selection)
    }

    private func resetFolderBrowsing() {
        guard isBrowsingFolder else { return }
        cancelFolderThumbnails()
        clearSelection()
        folderBrowser.reset()
    }

    private func cancelFolderThumbnails() {
        for item in folderBrowser.items {
            if let request = thumbnails.removeValue(forKey: item.id) { QLThumbnailGenerator.shared.cancel(request) }
        }
    }

    @discardableResult func receivePromise(_ receiver: NSFilePromiseReceiver) -> Bool {
        let id = UUID()
        let expected = generation
        do {
            let destination = try managedFiles.makeDestination()
            imports[id] = receiver
            items.append(ShelfItem(id: id, name: "正在接收文件", subtitle: "等待来源应用…", state: .loading,
                                   icon: NSWorkspace.shared.icon(for: .data)))
            // The callback owns the destination until the producer finishes. Do not capture the
            // receiver here: it owns this callback, so doing so would prevent cleanup after close.
            receiver.receivePromisedFiles(atDestination: destination.url, options: [:], operationQueue: managedFiles.queue) { [weak self, destination] url, error in
                Task { @MainActor in
                    guard let self, self.generation == expected, self.imports[id] != nil else { return }
                    if let error {
                        if let index = self.items.firstIndex(where: { $0.id == id }) {
                            self.items[index].state = .unavailable("来源应用未能提供文件，可移除后重试")
                            self.items[index].subtitle = "接收失败"
                        }
                        Logger.files.error("Inbound promise failed: \(error.localizedDescription, privacy: .private)")
                        self.notice = "部分文件未能接收，请从来源应用重新拖入。"
                    } else {
                        self.items.removeAll { $0.id == id }
                        _ = self.add([url], managedDirectory: destination)
                    }
                }
            }
            importTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled, let self else { return }
                self.imports.removeValue(forKey: id)
                self.importTimeouts.removeValue(forKey: id)
                if let index = self.items.firstIndex(where: { $0.id == id }), self.items[index].state == .loading {
                    self.items[index].state = .unavailable("来源应用响应超时，请重新拖入")
                    self.items[index].subtitle = "接收超时"
                }
            }
            return true
        } catch {
            notice = "无法创建临时接收目录，请稍后重试。"
            Logger.files.error("Promise directory failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
