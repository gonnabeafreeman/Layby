import Foundation

#if canImport(Sparkle)
import Sparkle

@MainActor
final class UpdateService: NSObject {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
#else
/// Keeps logic tests independent from the app-only Sparkle framework.
@MainActor
final class UpdateService {
    func checkForUpdates() {}
}
#endif
