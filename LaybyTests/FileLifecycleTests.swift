import AppKit
import Testing
import SwiftUI
@testable import LaybyKit

@MainActor @Suite(.serialized)
struct FileLifecycleTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func settle(_ store: ShelfStore) async {
        for _ in 0..<200 {
            if !store.items.contains(where: { $0.state == .loading }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func shiftSelectionExtendsShrinksAndResetsItsAnchor() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (0..<5).map { root.appendingPathComponent("range-\($0).txt") }
        for file in files { try Data("file".utf8).write(to: file) }
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add(files)
        await settle(store)
        let ids = store.items.map(\.id)
        store.select(ids[1], extending: false)
        store.select(ids[4], extending: false, range: true)
        #expect(store.selection == Set(ids[1...4]))
        store.select(ids[2], extending: false, range: true)
        #expect(store.selection == Set(ids[1...2]))
        store.select(ids[0], extending: false, range: true)
        #expect(store.selection == Set(ids[0...1]))
        store.select(ids[4], extending: true)
        store.select(ids[3], extending: true, range: true)
        #expect(store.selection == Set([ids[0], ids[1], ids[3], ids[4]]))
        store.clearSelection()
        store.select(ids[2], extending: false, range: true)
        #expect(store.selection == [ids[2]])
        store.remove([ids[2]])
        store.select(ids[4], extending: false, range: true)
        #expect(store.selection == [ids[4]])
    }

    @Test func releasingShiftBeforeMouseUpPreservesTheRange() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (0..<3).map { root.appendingPathComponent("click-\($0).txt") }
        for file in files { try Data("file".utf8).write(to: file) }
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add(files)
        await settle(store)
        let ids = store.items.map(\.id)
        let row = FileDragView(store: store, scope: .item(ids[2]), content: Text("test"))
        store.select(ids[0], extending: false)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        row.mouseDown(with: down)
        row.mouseUp(with: up)
        #expect(store.selection == Set(ids))
    }

    @Test func moveShortcutKeepsSelectedFilesTogetherUntilDragStarts() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (0..<3).map { root.appendingPathComponent("move-selection-\($0).txt") }
        for file in files { try Data("file".utf8).write(to: file) }
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add(files)
        await settle(store)
        let ids = store.items.map(\.id)
        store.select(ids[0], extending: false)
        store.select(ids[1], extending: true)
        let row = FileDragView(store: store, scope: .item(ids[1]), content: Text("test"))
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        row.mouseDown(with: down)
        #expect(store.selection == Set(ids[0...1]))
        #expect(store.dragItems(for: .item(ids[1])).map(\.id) == Array(ids[0...1]))
    }

    @Test func selectionSummaryCountsOnlySelectedFilesAndHandlesUnknownSizes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (0..<3).map { root.appendingPathComponent("size-\($0).txt") }
        for (index, file) in files.enumerated() { try Data(repeating: 65, count: (index + 1) * 100).write(to: file) }
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add(files + [root.appendingPathComponent("missing.txt")])
        await settle(store)
        let ids = store.items.map(\.id)
        #expect(store.selectionSummary == nil)
        store.select(ids[0], extending: false)
        store.select(ids[1], extending: true)
        let size = ByteCountFormatter.string(fromByteCount: 300, countStyle: .file)
        #expect(store.selectionSummary == L10n.format("已选择 %d 个文件 · %@", 2, size))
        store.select(ids[3], extending: true)
        #expect(store.selectionSummary == L10n.format("已选择 %d 个文件 · %@", 3, L10n.text("大小未知")))
        store.clearSelection()
        #expect(store.selectionSummary == nil)
    }

    @Test func stackExportsAllAndSelectedCardsExportTheSelection() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (0..<8).map { root.appendingPathComponent("file-\($0).txt") }
        for file in files { try Data("file".utf8).write(to: file) }
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add(files)
        await settle(store)
        let ids = store.items.map(\.id)
        let first = try #require(ids.first)
        let last = try #require(ids.last)
        store.select(first, extending: false)
        #expect(store.dragItems(for: .all).count == 8)
        for mode in [ShelfPresentation.list, .grid] {
            store.present(mode)
            store.select(ids[1], extending: false)
            store.select(ids[4], extending: false, range: true)
            let row = FileDragView(store: store, scope: .item(ids[2]), content: Text("selected"))
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            row.mouseDown(with: down)
            #expect(store.selection == Set(ids[1...4]))
            #expect(store.dragItems(for: .item(ids[2])).map(\.id) == Array(ids[1...4]))
            #expect(store.dragItems(for: .item(last)).map(\.id) == [last])
            let unselectedRow = FileDragView(store: store, scope: .item(last), content: Text("unselected"))
            unselectedRow.mouseDown(with: down)
            #expect(store.selection == [last])
            #expect(store.dragItems(for: .item(last)).map(\.id) == [last])
            store.select(first, extending: false)
            store.select(last, extending: true)
            #expect(store.dragItems(for: .item(last)).map(\.id) == [first, last])
            store.selection = Set(ids)
            #expect(store.dragItems(for: .item(last)).map(\.id) == ids)
            #expect(store.dragItems(for: .all).map(\.id) == ids)
        }
        #expect(store.dragItems(for: .item(UUID())).isEmpty)
    }

    @Test func selectedDragDoesNotSilentlySkipUnavailableFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (0..<2).map { root.appendingPathComponent("ready-\($0).txt") }
        for file in files { try Data("ready".utf8).write(to: file) }
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add(files + [root.appendingPathComponent("missing.txt")])
        await settle(store)
        let ids = store.items.map(\.id)
        store.present(.list)
        store.selection = [ids[0], ids[2]]
        #expect(store.dragItems(for: .item(ids[0])).isEmpty)
        #expect(store.dragItems(for: .item(ids[2])).isEmpty)
        #expect(store.dragItems(for: .item(ids[1])).map(\.id) == [ids[1]])
        store.select(ids[2], extending: true)
        #expect(store.dragItems(for: .item(ids[0])).map(\.id) == [ids[0]])
    }

    @Test func incompleteStackDoesNotSilentlyExportOnlySomeFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ready.txt")
        try Data("ready".utf8).write(to: file)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([file, root.appendingPathComponent("missing.txt")])
        #expect(store.dragItems(for: .all).isEmpty)
        await settle(store)
        #expect(store.dragItems(for: .all).isEmpty)
        let readyID = try #require(store.readyItems.first?.id)
        #expect(store.dragItems(for: .item(readyID)).count == 1)
        store.remove(Set(store.items.filter { !$0.state.isReady }.map(\.id)))
        #expect(store.dragItems(for: .all).count == 1)
    }

    @Test func moveDragRemovesOriginalOnlyAfterDestinationReportsMove() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try Data("content".utf8).write(to: source)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")),
                               noticeDuration: .seconds(10))
        store.add([source])
        await settle(store)
        let entry = try #require(store.items.first)

        store.reconcileMovedDrag([entry], operation: .copy, attempts: 1)
        store.reconcileMovedDrag([entry], operation: [], attempts: 1)
        #expect(store.items.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        // Stand in for Finder's completed destination-side transfer.
        try FileManager.default.copyItem(at: source, to: destination)
        store.reconcileMovedDrag([entry], operation: .move, attempts: 1)
        for _ in 0..<50 where !store.items.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func moveDragDoesNotDeleteAReplacementAtTheOldPath() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let moved = root.appendingPathComponent("moved.txt")
        try Data("old".utf8).write(to: original)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")),
                               noticeDuration: .seconds(10))
        store.add([original])
        await settle(store)
        let entry = try #require(store.items.first)
        try FileManager.default.moveItem(at: original, to: moved)
        try Data("new".utf8).write(to: original)

        store.reconcileMovedDrag([entry], operation: .move, attempts: 1)
        for _ in 0..<50 where !store.items.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.items.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "new")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "old")
    }

    @Test func presentationResetsOnClearAndLastRemoval() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: file)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.present(.grid)
        #expect(store.presentation == .stack)
        store.add([file])
        await settle(store)
        store.present(.grid)
        #expect(store.presentation == .grid)
        store.present(.list)
        #expect(store.presentation == .list)
        store.clear()
        #expect(store.presentation == .stack)
        store.add([file])
        await settle(store)
        store.present(.grid)
        store.remove(Set(store.items.map(\.id)))
        #expect(store.presentation == .stack)
    }

    private func waitForRemoval(_ url: URL) async {
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: url.path) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func quickLookOnlyUsesReadySelectionInExpandedViews() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preview.txt")
        try Data("preview".utf8).write(to: file)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([file, root.appendingPathComponent("missing.txt")])
        await settle(store)
        let readyID = try #require(store.readyItems.first?.id)
        store.selection = Set(store.items.map(\.id))
        #expect(store.previewItems.isEmpty)
        for mode in [ShelfPresentation.grid, .list] {
            store.present(mode)
            #expect(store.previewItems.isEmpty)
            store.selection = Set(store.items.map(\.id))
            #expect(store.previewItems.map(\.id) == [readyID])
        }
        var changed = false
        store.onPreviewChange = { changed = true }
        store.remove([readyID])
        #expect(changed)
        #expect(store.previewItems.isEmpty)
    }

    @Test func quickLookRetainsPromisedFileUntilPreviewItemIsReleased() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = ManagedFileStore(root: root)
        let store = ShelfStore(managedFiles: managed)
        var directory: ManagedFileDirectory? = try managed.makeDestination()
        let destination = try #require(directory?.url)
        let file = destination.appendingPathComponent("preview.txt")
        try Data("preview".utf8).write(to: file)
        store.add([file], managedDirectory: directory)
        directory = nil
        await settle(store)
        var preview = store.items.first.flatMap(ShelfPreviewItem.init)
        #expect(preview?.previewItemTitle == "preview.txt")
        store.clear()
        #expect(try String(contentsOf: try #require(preview?.previewItemURL), encoding: .utf8) == "preview")
        preview = nil
        await waitForRemoval(destination)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func quickLookKeysRespectModifiersAndEscapeDoesNotCloseShelf() {
        _ = NSApplication.shared
        let panel = ShelfPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        var opened = 0
        var closedShelf = 0
        var previewVisible = false
        panel.onQuickLook = { opened += 1; previewVisible = true; return true }
        panel.onHide = { closedShelf += 1 }
        panel.dismissQuickLook = {
            guard previewVisible else { return false }
            previewVisible = false
            return true
        }
        func space(_ modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: repeating, keyCode: 49)!
        }
        for modifier in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            #expect(!panel.handleQuickLookKey(space(modifier)))
        }
        #expect(opened == 0)
        #expect(panel.performKeyEquivalent(with: space()))
        #expect(panel.handleQuickLookKey(space(repeating: true)))
        #expect(opened == 1)
        panel.cancelOperation(nil)
        #expect(!previewVisible)
        #expect(closedShelf == 0)
        panel.cancelOperation(nil)
        #expect(closedShelf == 1)
    }

    @Test func closeRoutesClearTheShelfAndKeepOriginals() async throws {
        _ = NSApplication.shared
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.txt")
        try Data("keep".utf8).write(to: file)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        let controller = ShelfWindowController(store: store)
        defer { controller.stop() }
        let actions: [() -> Void] = [
            { controller.hide() },
            { controller.panel.close() },
            { controller.panel.performClose(nil) },
            { controller.panel.cancelOperation(nil) },
            {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                    isARepeat: false, keyCode: 13)!
                #expect(controller.panel.performKeyEquivalent(with: event))
            }
        ]
        for close in actions {
            store.add([file])
            await settle(store)
            store.selection = Set(store.items.map(\.id))
            store.notice = "已复制"
            store.isDropTargeted = true
            close()
            #expect(store.items.isEmpty)
            #expect(store.selection.isEmpty)
            #expect(store.notice == nil)
            #expect(!store.isDropTargeted)
            store.refreshReferences()
            #expect(store.items.isEmpty)
            #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        }
    }

    @Test func clearDeletesManagedFilesAfterReadersRelease() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = ManagedFileStore(root: root)
        let store = ShelfStore(managedFiles: managed)
        var directory: ManagedFileDirectory? = try managed.makeDestination()
        let destination = try #require(directory?.url)
        let file = destination.appendingPathComponent("promise.txt")
        try Data("received".utf8).write(to: file)
        store.add([file], managedDirectory: directory)
        directory = nil
        await settle(store)
        var outboundLease: FileAccessLease? = store.items.first?.lease
        store.clear()
        #expect(store.items.isEmpty)
        #expect(try String(contentsOf: try #require(outboundLease?.url), encoding: .utf8) == "received")
        outboundLease = nil
        await waitForRemoval(destination)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func latePromiseAfterCloseIsDeletedWithoutReappearing() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root))
        let receiver = DelayedPromiseReceiver()
        #expect(store.receivePromise(receiver))
        let destination = try #require(receiver.destination)
        store.clear()
        // The producer still owns its destination, even though its shelf has been closed.
        #expect(FileManager.default.fileExists(atPath: destination.path))
        try receiver.deliver()
        await waitForRemoval(destination)
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func duplicateURLIsIgnoredButSameNamesAreRetained() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.txt")
        let directory = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let second = directory.appendingPathComponent("a.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        #expect(store.add([first, first, second]) == 2)
        await settle(store)
        #expect(store.readyItems.count == 2)
        store.clear()
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
    }

    @Test func clearInvalidatesLateMetadata() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.txt")
        try Data("keep me".utf8).write(to: file)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([file])
        store.clear()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unavailableFileCanBeRetried() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("later.txt")
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([file])
        await settle(store)
        #expect(store.readyItems.isEmpty)
        let id = try #require(store.items.first?.id)
        try Data("now available".utf8).write(to: file)
        store.retry(id)
        await settle(store)
        #expect(store.readyItems.count == 1)
    }

    @Test func deletingReferencesDoesNotDeleteOriginals() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.txt")
        try Data("original".utf8).write(to: file)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([file])
        await settle(store)
        let id = try #require(store.items.first?.id)
        store.select(id, extending: false)
        store.remove([id])
        #expect(store.selection.isEmpty)
        #expect(store.items.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }
}

private final class DelayedPromiseReceiver: NSFilePromiseReceiver {
    var destination: URL?
    private var reader: ((URL, Error?) -> Void)?

    override func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any],
                                       operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        destination = destinationDir
        self.reader = reader
    }

    func deliver() throws {
        let file = try #require(destination).appendingPathComponent("late.txt")
        try Data("late result".utf8).write(to: file)
        reader?(file, nil)
        reader = nil
    }
}
