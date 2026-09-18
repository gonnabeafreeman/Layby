import AppKit
import Testing
@testable import LaybyKit

@MainActor @Suite(.serialized)
struct FileServiceCatalogTests {
    private func declaration(_ name: String, types: [String], context: [String: Any] = [:],
                             fileTypes: [String] = []) -> [String: Any] {
        ["NSMenuItem": ["default": name], "NSSendTypes": types,
         "NSRequiredContext": context, "NSSendFileTypes": fileTypes]
    }

    @Test func discoversFileOperationsIncludingFinderContextButExcludesTextOnlyServices() {
        let info: [String: Any] = ["CFBundleIdentifier": "test.services", "NSServices": [
            declaration("Add to Dropover", types: ["NSURLPboardType", "NSStringPboardType"]),
            declaration("Keka/Compress using Keka", types: ["NSFilenamesPboardType"]),
            declaration("Compress with Bandizip", types: ["NSFilenamesPboardType"], context: ["NSApplicationIdentifier": "com.apple.finder"]),
            declaration("Upload file in Transmit", types: ["public.file-url"], fileTypes: ["public.file-url", "public.directory"]),
            declaration("Open in Windows", types: ["NSPasteboardTypeString"], context: ["NSTextContent": "FilePath"], fileTypes: ["public.data"]),
            declaration("Search selected text", types: ["NSStringPboardType"]),
            declaration("Editor only", types: ["NSFilenamesPboardType"], context: ["NSApplicationIdentifier": "test.editor"])
        ]]
        let entries = FileService.declarations(in: info, bundleURL: URL(fileURLWithPath: "/tmp/TestServices.app"))
        #expect(entries.map(\.title) == ["Add to Dropover", "Compress using Keka", "Compress with Bandizip", "Upload file in Transmit", "Open in Windows"])
        #expect(entries[1].invocationName == "Keka/Compress using Keka")
    }

    @Test func installedScreenshotProvidersAppearInDiscoveredCatalog() async throws {
        let entries = await Task.detached { FileServiceCatalog.discover() }.value
        for name in ["Dropover", "Keka", "Bandizip", "Transmit", "Parallels Desktop"] {
            let bundleURL = URL(fileURLWithPath: "/Applications/\(name).app")
            guard let info = Bundle(url: bundleURL)?.infoDictionary else { continue }
            let declared = FileService.declarations(in: info, bundleURL: bundleURL)
            #expect(!declared.isEmpty)
            for service in declared { #expect(entries.contains { $0.id == service.id }) }
        }
    }

    @Test func menuCallsSelectedFileOperationWithFrozenCompleteSelectionAndReportsFailures() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaybyFileServices-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try ["one.pdf", "two.pdf"].map { name in
            let url = root.appendingPathComponent(name)
            try Data("test".utf8).write(to: url)
            return url
        }
        let store = ShelfStore()
        store.add(urls)
        for _ in 0..<200 {
            if store.items.allSatisfy({ $0.state.isReady }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entry = FileService(id: "test.keka", title: "Compress using Keka", invocationName: "Keka/Compress using Keka",
                                applicationName: "Keka", fileTypes: ["public.data"])
        let textOnly = FileService(id: "test.text", title: "Process text files", invocationName: "Process text files",
                                   applicationName: "Test", fileTypes: ["public.plain-text"])
        var invoked: [(String, [String], String?, [URL])] = []
        let services = ShelfServicesController(store: store, catalog: FileServiceCatalog(entries: [entry, textOnly]),
                                                performService: { name, board in
            invoked.append((name, board.propertyList(forType: ShelfServicesController.filenamesType) as? [String] ?? [],
                            board.string(forType: .init("NSPasteboardTypeString")),
                            board.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []))
            return false // No third-party application is executed by this test.
        })
        defer { services.stop(); store.clear() }
        let menu = services.fileServicesMenu()
        #expect(menu.items.map(\.title) == [entry.title])
        // The open stack menu still represents both original files, even if
        // the live selection changes before the command is dispatched.
        store.present(.list)
        store.selection = [store.items[0].id]
        menu.performActionForItem(at: 0)
        #expect(invoked.count == 1)
        #expect(invoked.first?.0 == entry.invocationName)
        #expect(invoked.first?.1 == urls.map(\.path))
        #expect(invoked.first?.2 == urls.map(\.path).joined(separator: "\n"))
        #expect(invoked.first?.3 == urls)
        #expect(store.notice?.contains(entry.title) == true)
        store.selection = Set(store.items.map(\.id))
        let context = try #require(services.contextMenu(for: store.items[0].id, preview: { _ in }))
        // The catalog now lives in the "Services" category, past the shared
        // quick actions (Finder, Quick Look, AirDrop, Mail, Messages) and the
        // context-specific management actions (retry, remove, clear).
        let submenu = try #require(context.items.last?.submenu)
        #expect(submenu.items.last?.title == entry.title)
        submenu.performActionForItem(at: submenu.items.count - 1)
        #expect(invoked.count == 2 && invoked.last?.1 == urls.map(\.path))
    }
}
