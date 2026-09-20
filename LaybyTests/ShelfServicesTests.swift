import AppKit
import SwiftUI
import Testing
@testable import LaybyKit

@MainActor @Suite(.serialized)
struct ShelfServicesTests {
    private func settle(_ store: ShelfStore) async throws {
        for _ in 0..<200 {
            if !store.items.contains(where: { $0.state == .loading }) && !store.folderBrowser.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("File inspection did not finish")
    }

    private func files(in root: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try ["one.txt", "two.txt", "three.txt"].map { name in
            let url = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
    }

    @Test func stackSendsEveryFileAsModernURLsAndLegacyFilenames() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyServices-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try files(in: root)
        let store = ShelfStore()
        store.add(urls)
        try await settle(store)
        store.selection = [try #require(store.items.first?.id)]
        let services = ShelfServicesController(store: store)
        defer { services.stop(); store.clear() }
        #expect(services.items.map(\.url) == urls)
        #expect(services.accepts(sendType: .fileURL, returnType: nil))
        #expect(services.accepts(sendType: ShelfServicesController.filenamesType, returnType: nil))
        #expect(services.accepts(sendType: .string, returnType: nil))
        #expect(!services.accepts(sendType: .fileURL, returnType: .string))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(services.writeSelection(to: board, types: ShelfServicesController.sendTypes))
        #expect(board.propertyList(forType: ShelfServicesController.filenamesType) as? [String] == urls.map(\.path))
        let written = (board.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        #expect(written == urls)
        #expect(services.writeSelection(to: board, types: [ShelfServicesController.filenamesType]))
        #expect(board.propertyList(forType: ShelfServicesController.filenamesType) as? [String] == urls.map(\.path))
    }

    @Test func stackAndFileMenusGroupFileActionsBeforeEveryAvailableShareService() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyServiceMenuGroups-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore()
        store.add(try files(in: root))
        try await settle(store)
        let alpha = root.appendingPathComponent("Alpha.app")
        let beta = root.appendingPathComponent("Beta.app")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: false)
        let shareIcon = try #require(NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil))
        let shareOne = NSSharingService(title: "Share One", image: shareIcon, alternateImage: nil) {}
        let shareTwo = NSSharingService(title: "Share Two", image: shareIcon, alternateImage: nil) {}
        let services = ShelfServicesController(
            store: store,
            catalog: FileServiceCatalog(entries: []),
            sharingServices: { _ in [shareOne, shareTwo] },
            applicationsForURL: { _ in [beta, alpha] },
            defaultApplicationForURL: { _ in alpha }
        )
        defer { services.stop(); store.clear() }

        let stackMenu = services.quickActionsMenu(quickLookEnabled: true, quickLookAction: {})
        #expect(stackMenu.items.count == 11)
        #expect(stackMenu.items[0...2].map(\.title) == ["用…打开", "在 Finder 中显示", "快速查看"].map(L10n.text))
        #expect(stackMenu.items[0...2].allSatisfy { $0.image != nil })
        #expect(stackMenu.items[3].isSeparatorItem)
        #expect(stackMenu.items[4...5].map(\.title) == [shareOne.title, shareTwo.title])
        #expect(stackMenu.items[4...5].allSatisfy { $0.isEnabled })
        #expect(stackMenu.items[6].isSeparatorItem)
        #expect(stackMenu.items[7...8].map(\.title) == ["复制到剪贴板", "从剪贴板粘贴"].map(L10n.text))
        #expect(stackMenu.items[9].isSeparatorItem)
        #expect(stackMenu.items[10].title == L10n.text("服务"))
        if #available(macOS 27.0, *) {
            #expect(stackMenu.items[0...2].allSatisfy { $0.preferredImageVisibility == .visible })
        }
        let openWith = stackMenu.items[0]
        let openWithApplications = (openWith.submenu?.items ?? []).filter {
            !$0.isSeparatorItem && $0.title != L10n.text("其他…")
        }
        #expect(openWithApplications.map(\.title) == ["Alpha", "Beta"])
        #expect(openWithApplications.allSatisfy { $0.image != nil })
        #expect(openWith.image?.tiffRepresentation == openWithApplications.first?.image?.tiffRepresentation)
        if #available(macOS 27.0, *) {
            #expect(openWith.preferredImageVisibility == .visible)
            #expect(openWithApplications.allSatisfy { $0.preferredImageVisibility == .visible })
        }

        let context = try #require(services.contextMenu(for: store.items[0].id, preview: { _ in }))
        #expect(context.items[0...2].map(\.title) == ["用…打开", "在 Finder 中显示", "快速查看"].map(L10n.text))
        #expect(context.items[3].isSeparatorItem)
        #expect(context.items[4...5].map(\.title) == [shareOne.title, shareTwo.title])
        #expect(context.items[6].isSeparatorItem)
        #expect(context.items[7...8].map(\.title) == ["复制到剪贴板", "从剪贴板粘贴"].map(L10n.text))
        #expect(context.items[9].isSeparatorItem)
        #expect(context.items[10].title == L10n.text("重新检查"))
        #expect(context.items[11].title == L10n.text("从停放区移除"))
        #expect(context.items[12].title == L10n.text("清空停放区"))
        #expect(context.items[13].isSeparatorItem)
        #expect(context.items[14].title == L10n.text("服务"))
    }

    @Test func menuOmitsOpenWithAndShareGroupsWhenNothingSupportsTheSelection() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyServiceMenuUnavailable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore()
        store.add(try files(in: root))
        try await settle(store)
        let services = ShelfServicesController(
            store: store,
            catalog: FileServiceCatalog(entries: []),
            sharingServices: { _ in [] },
            applicationsForURL: { _ in [] },
            defaultApplicationForURL: { _ in nil }
        )
        defer { services.stop(); store.clear() }

        let menu = services.quickActionsMenu(quickLookEnabled: true, quickLookAction: {})
        #expect(menu.items.map(\.title) == [L10n.text("在 Finder 中显示"), L10n.text("快速查看"), "",
            L10n.text("复制到剪贴板"), L10n.text("从剪贴板粘贴"), "", L10n.text("服务")])
        #expect(menu.items[2].isSeparatorItem)
        #expect(!menu.items.contains { $0.title == L10n.text("用…打开") })
    }

    @Test func clipboardGroupCopiesSelectionAndPastesFilesIntoTheShelf() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyClipboardMenu-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try files(in: root)
        let pasted = root.appendingPathComponent("pasted.txt")
        try Data("pasted".utf8).write(to: pasted)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ShelfStore()
        store.add(urls)
        try await settle(store)
        store.present(.list)
        store.selection = [store.items[1].id]
        let services = ShelfServicesController(store: store, catalog: FileServiceCatalog(entries: []), clipboard: board)
        defer { services.stop(); store.clear() }

        var menu = try #require(services.contextMenu(for: store.items[1].id, preview: { _ in }))
        let copyIndex = try #require(menu.items.firstIndex { $0.title == L10n.text("复制到剪贴板") })
        #expect(menu.items[copyIndex].isEnabled)
        menu.performActionForItem(at: copyIndex)
        let copied = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        #expect(copied == [urls[1]])

        board.clearContents()
        #expect(board.writeObjects([pasted as NSURL]))
        menu = try #require(services.backgroundContextMenu())
        #expect(menu.items.map(\.title) == [L10n.text("复制到剪贴板"), L10n.text("从剪贴板粘贴"), "",
            L10n.text("重新检查"), L10n.text("清空停放区")])
        #expect(menu.items[2].isSeparatorItem)
        #expect(!menu.items.contains { $0.title == L10n.text("服务") || $0.title == L10n.text("从停放区移除") })
        let pasteIndex = try #require(menu.items.firstIndex { $0.title == L10n.text("从剪贴板粘贴") })
        #expect(menu.items[pasteIndex].isEnabled)
        menu.performActionForItem(at: pasteIndex)
        try await settle(store)
        #expect(store.items.contains { $0.url?.standardizedFileURL == pasted.standardizedFileURL })
    }

    @Test func operationNoticesDisappearAndNewMessagesRestartTheDismissalWindow() async throws {
        let store = ShelfStore(noticeDuration: .milliseconds(100))
        store.notice = "First"
        try await Task.sleep(for: .milliseconds(60))
        store.notice = "Second"
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.notice == "Second")
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.notice == nil)
    }

    @Test func rightClickPreservesMultiSelectionAndUsesThePanelRequestor() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyServiceSelection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore()
        store.add(try files(in: root))
        try await settle(store)
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop() }
        let services = try #require(shelf.panel.services)
        for mode in [ShelfPresentation.grid, .list] {
            store.present(mode)
            shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
            let ids = store.items.map(\.id)
            store.selection = [ids[0], ids[2]]
            let view = FileDragView(store: store, scope: .item(ids[2]), content: Text("Test file"))
            shelf.panel.contentView?.addSubview(view)
            defer { view.removeFromSuperview() }
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: shelf.panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try #require(view.menu(for: event))
            #expect(!menu.allowsContextMenuPlugIns)
            #expect(store.selection == [ids[0], ids[2]])
            #expect(services.items.map(\.id) == [ids[0], ids[2]])
            #expect(shelf.panel.firstResponder === view)
            let requestor = shelf.panel.validRequestor(forSendType: .fileURL, returnType: nil)
            #expect((requestor as? ShelfServicesController) === services)
            services.prepareContext(for: ids[1])
            #expect(store.selection == [ids[1]])
            #expect(services.items.map(\.id) == [ids[1]])
        }
    }

    @Test func expandedBrowsersActivateOnlyOnContextClickNotPlainSelectionOrDrag() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyPanelActivation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore()
        store.add(try files(in: root))
        try await settle(store)
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop(); store.clear() }

        #expect(!shelf.panel.activatesOnInteraction)
        store.present(.list)
        #expect(shelf.panel.activatesOnInteraction)
        #expect(shelf.panel.styleMask.contains(.nonactivatingPanel))
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)
        shelf.panel.resignKey()

        // A plain click — the same event that begins a drag-out — must never
        // call NSApp.activate and steal focus from whatever window the user is
        // about to drop onto. The panel may still become key on its own (normal
        // AppKit behavior for a nonactivating panel), which never activates the app.
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: shelf.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        shelf.panel.sendEvent(click)
        #expect(!shelf.panel.hasPendingInteractionFocus)

        // A context-menu request still needs the shelf focused so the menu works.
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: shelf.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        shelf.panel.sendEvent(rightClick)
        #expect(shelf.panel.isKeyWindow || shelf.panel.hasPendingInteractionFocus)

        store.present(.grid)
        #expect(shelf.panel.activatesOnInteraction)
        #expect(shelf.panel.styleMask.contains(.nonactivatingPanel))
        store.present(.stack)
        #expect(!shelf.panel.activatesOnInteraction)
        #expect(shelf.panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test func enteringListModeNeverActivatesUntilAContextClick() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyListFocusRace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore()
        store.add(try files(in: root))
        try await settle(store)
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop(); store.clear() }
        shelf.show(near: CGPoint(x: 500, y: 500), focus: false)

        #expect(!shelf.panel.activatesOnInteraction)
        store.present(.list)
        #expect(shelf.panel.activatesOnInteraction)
        // Switching into the browser is itself not a click; it must not activate on its own.
        #expect(!shelf.panel.hasPendingInteractionFocus)

        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: shelf.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        shelf.panel.sendEvent(rightClick)
        #expect(shelf.panel.isKeyWindow || shelf.panel.hasPendingInteractionFocus)
    }

    @Test func unavailableGroupsNeverSendPartialSelections() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyServiceUnavailable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try files(in: root)
        let store = ShelfStore()
        let services = ShelfServicesController(store: store)
        defer { services.stop(); store.clear() }
        #expect(services.items.isEmpty)
        store.add(urls)
        #expect(services.items.isEmpty)
        try await settle(store)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("unchanged", forType: .string)
        #expect(!services.writeSelection(to: board, types: [.rtf]))
        #expect(board.string(forType: .string) == "unchanged")
        try FileManager.default.removeItem(at: urls[1])
        #expect(!services.writeSelection(to: board, types: [.fileURL]))
        #expect(board.string(forType: .string) == "unchanged")
        #expect(store.notice != nil)
        store.add([root.appendingPathComponent("missing.txt")])
        try await settle(store)
        #expect(services.items.isEmpty)
        store.present(.list)
        store.selection = [store.items[0].id, try #require(store.items.last?.id)]
        #expect(services.items.isEmpty)
        store.selection = [store.items[0].id]
        #expect(services.items.count == 1)
    }

    @Test func servicesKeepManagedFolderChildrenAliveAfterClosingShelf() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyServiceLifetime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = ManagedFileStore(root: root)
        var directory: ManagedFileDirectory? = try managed.makeDestination()
        let folder = try #require(directory?.url)
        let urls = try files(in: folder)
        let store = ShelfStore(managedFiles: managed)
        let shelf = ShelfWindowController(store: store)
        defer { shelf.stop() }
        store.add([folder], managedDirectory: directory)
        directory = nil
        try await settle(store)
        store.present(.grid)
        store.openFolder(try #require(store.items.first?.id))
        try await settle(store)
        store.selection = Set(store.visibleItems.map(\.id))
        let services = try #require(shelf.panel.services)
        #expect(Set(services.items.compactMap { $0.url?.resolvingSymlinksInPath() }) == Set(urls.map { $0.resolvingSymlinksInPath() }))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(services.writeSelection(to: board, types: [.fileURL]))
        shelf.hide()
        try await Task.sleep(for: .milliseconds(80))
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        services.stop()
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: folder.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func applicationRegistersAnActualSystemServicesMenu() {
        _ = NSApplication.shared
        let previous = NSApp.servicesMenu
        defer { NSApp.servicesMenu = previous }
        let applicationMenu = NSMenu(title: "Layby")
        ShelfServicesController.installMenu(in: applicationMenu)
        #expect(NSApp.servicesMenu != nil)
        #expect(NSApp.servicesMenu?.supermenu === applicationMenu)
    }
}
