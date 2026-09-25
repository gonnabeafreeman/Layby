import AppKit
import Testing
@testable import LaybyKit

@MainActor @Suite(.serialized)
struct FolderBrowserTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("LaybyFolders-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func settle(_ store: ShelfStore) async {
        for _ in 0..<200 {
            if !store.items.contains(where: { $0.state == .loading }) && !store.folderBrowser.isLoading { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.folderBrowser.isLoading)
    }

    @Test func nestedAndEmptyFoldersReturnToEachParentWithoutChangingShelf() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        let nested = folder.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: folder.appendingPathComponent("file.txt"))
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([folder])
        await settle(store)
        let rootID = try #require(store.items.first?.id)
        for mode in [ShelfPresentation.list, .grid] {
            store.present(mode)
            store.openFolder(rootID)
            await settle(store)
            #expect(store.folderBrowser.directory?.url == folder)
            #expect(store.visibleItems.map(\.name) == ["Nested", "file.txt"])
            #expect(store.items.map(\.id) == [rootID])
            let nestedID = try #require(store.visibleItems.first?.id)
            store.openFolder(nestedID)
            await settle(store)
            #expect(store.folderBrowser.depth == 2)
            #expect(store.visibleItems.isEmpty)
            #expect(store.folderBrowser.error == nil)
            #expect(store.presentation == mode)
            store.goBack()
            #expect(store.folderBrowser.directory?.url == folder)
            #expect(store.selection == [nestedID])
            store.goBack()
            #expect(!store.isBrowsingFolder)
            #expect(store.visibleItems.map(\.id) == [rootID])
            #expect(store.selection == [rootID])
            #expect(store.presentation == mode)
            store.goBack()
            #expect(store.presentation == .stack)
        }
    }

    @Test func childSelectionExportsAndPreviewsChildrenWithoutRemovingOriginals() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (1...3).map { folder.appendingPathComponent("file\($0).txt") }
        for file in files { try Data("file".utf8).write(to: file) }
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([folder])
        await settle(store)
        store.present(.list)
        store.openFolder(try #require(store.items.first?.id))
        await settle(store)
        let ids = store.visibleItems.map(\.id)
        store.select(ids[0], extending: false)
        store.select(ids[2], extending: false, range: true)
        // Directory enumeration may return /private/var while fixture URLs use
        // /var; normalize complete file URLs on both sides of the comparison.
        let resolvedFiles = files.map { $0.resolvingSymlinksInPath() }
        #expect(store.dragItems(for: .item(ids[1])).compactMap(\.url).map { $0.resolvingSymlinksInPath() } == resolvedFiles)
        #expect(store.previewItems.compactMap(\.url).map { $0.resolvingSymlinksInPath() } == resolvedFiles)
        #expect(store.dragItems(for: .all).compactMap(\.url) == [folder])
        store.select(ids[0], extending: false)
        #expect(store.moveSelection(.right))
        #expect(store.selection == [ids[1]])
        #expect(store.previewItems.first?.url?.resolvingSymlinksInPath() == resolvedFiles[1])
        store.removeSelection()
        #expect(store.visibleItems.count == 3)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        store.present(.grid)
        #expect(store.isBrowsingFolder)
        #expect(store.visibleItems.compactMap(\.url).map { $0.resolvingSymlinksInPath() } == resolvedFiles)
        store.clear()
        #expect(store.folderBrowser.depth == 0)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func movedChildRefreshesFolderWithoutRemovingItsShelfRoot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("child.txt")
        let sibling = folder.appendingPathComponent("sibling.txt")
        let destination = root.appendingPathComponent("moved.txt")
        try Data("child".utf8).write(to: child)
        try Data("sibling".utf8).write(to: sibling)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([folder])
        await settle(store)
        let rootID = try #require(store.items.first?.id)
        store.present(.list)
        store.openFolder(rootID)
        await settle(store)
        let childItem = try #require(store.visibleItems.first(where: { $0.name == "child.txt" }))
        try FileManager.default.copyItem(at: child, to: destination)

        store.reconcileMovedDrag([childItem], operation: .move, attempts: 1)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: child.path) || store.folderBrowser.isLoading {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await settle(store)
        #expect(store.items.map(\.id) == [rootID])
        #expect(store.visibleItems.map(\.name) == ["sibling.txt"])
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func closeAndBackDiscardPendingDirectoryResults() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("file".utf8).write(to: root.appendingPathComponent("file.txt"))
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([root])
        await settle(store)
        let id = try #require(store.items.first?.id)
        store.present(.grid)
        store.openFolder(id)
        store.goBack()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!store.isBrowsingFolder)
        #expect(store.visibleItems.map(\.id) == [id])
        store.openFolder(id)
        store.clear()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.folderBrowser.depth == 0)
        #expect(store.visibleItems.isEmpty)
        #expect(store.presentation == .stack)
    }

    @Test func missingFolderShowsRecoverableErrorAndRootRemovalEndsBrowsing() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ShelfStore(managedFiles: ManagedFileStore(root: root.appendingPathComponent("managed")))
        store.add([folder])
        await settle(store)
        let id = try #require(store.items.first?.id)
        try FileManager.default.removeItem(at: folder)
        store.present(.list)
        store.openFolder(id)
        await settle(store)
        #expect(store.folderBrowser.error != nil)
        #expect(store.folderBrowser.depth == 1)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.reloadFolder()
        await settle(store)
        #expect(store.folderBrowser.error == nil)
        store.remove([id])
        #expect(!store.isBrowsingFolder)
        #expect(store.items.isEmpty)
    }

    @Test func childPreviewRetainsManagedParentUntilTheLastReaderFinishes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = ManagedFileStore(root: root)
        let store = ShelfStore(managedFiles: managed)
        var directory: ManagedFileDirectory? = try managed.makeDestination()
        let destination = try #require(directory?.url)
        let folder = destination.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("child.txt")
        try Data("child".utf8).write(to: file)
        store.add([folder], managedDirectory: directory)
        directory = nil
        await settle(store)
        store.present(.grid)
        store.openFolder(try #require(store.items.first?.id))
        await settle(store)
        #expect(store.visibleItems.first?.isManaged == true)
        var preview = store.visibleItems.first.flatMap(ShelfPreviewItem.init)
        store.clear()
        #expect(try String(contentsOf: try #require(preview?.previewItemURL), encoding: .utf8) == "child")
        preview = nil
        for _ in 0..<200 where FileManager.default.fileExists(atPath: destination.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
