import AppKit

/// AppKit owns the application lifecycle; SwiftUI supplies the panel contents.
@main
enum LaybyApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator = AppCoordinator()
        coordinator?.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
