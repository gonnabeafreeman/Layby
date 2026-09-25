import Foundation
import Testing
@testable import LaybyKit

@MainActor @Suite(.serialized)
struct SettingsTests {
    private final class LoginItemStub: LaunchAtLoginManaging {
        var status: LaunchAtLoginStatus
        var error: Error?
        private(set) var openedSystemSettings = false

        init(status: LaunchAtLoginStatus) { self.status = status }

        func setEnabled(_ enabled: Bool) throws {
            if let error { throw error }
            status = enabled ? .enabled : .disabled
        }

        func openSystemSettings() { openedSystemSettings = true }
    }

    @Test func languageAndActivationChoicesSurviveReload() throws {
        let suite = "Layby.SettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.language == .system)
        #expect(settings.menuBarEnabled)
        #expect(settings.automaticUpdateChecksEnabled)
        #expect(settings.moveShortcut == .commandShift)
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.language = .english
        settings.shakeEnabled = false
        settings.modifierEnabled = false
        settings.notchEnabled = false
        settings.hotKeyEnabled = false
        settings.topEdgeEnabled = true
        settings.menuBarEnabled = false
        settings.automaticUpdateChecksEnabled = false
        settings.moveShortcut = .commandOption
        let restored = AppSettings(defaults: defaults)
        #expect(restored.language == .english)
        #expect(!restored.shakeEnabled && !restored.modifierEnabled)
        #expect(!restored.notchEnabled && !restored.hotKeyEnabled)
        #expect(restored.topEdgeEnabled)
        #expect(!restored.menuBarEnabled && !restored.automaticUpdateChecksEnabled)
        #expect(restored.moveShortcut == .commandOption)
        #expect(changes == 9)
        restored.language = .chinese
        #expect(AppSettings(defaults: defaults).language == .chinese)
        restored.language = .system
        #expect(AppSettings(defaults: defaults).language == .system)
    }

    @Test func invalidSavedLanguageFallsBackToSystem() throws {
        let suite = "Layby.SettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unsupported", forKey: "language")
        #expect(AppSettings(defaults: defaults).language == .system)
    }

    @Test func moveDragShortcutRequiresItsWholeModifierCombination() {
        #expect(MoveDragShortcut.commandShift.matches([.command, .shift]))
        #expect(!MoveDragShortcut.commandShift.matches(.command))
        #expect(!MoveDragShortcut.commandShift.matches([.command, .shift, .option]))
        #expect(MoveDragShortcut.commandOption.matches([.command, .option]))
    }

    @Test func systemLanguageUsesSupportedPreferencesAndOverridesWin() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW", "en-US"]) == .chinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-Hans"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh_CN"]) == .chinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .english)
        #expect(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]) == .english)
        #expect(AppLanguage.chinese.resolved(preferredLanguages: ["en-US"]) == .chinese)
    }

    @Test func translatedUIAndShortcutLabelsChangeImmediately() {
        defer { L10n.configure(.system) }
        L10n.configure(.english)
        #expect(L10n.text("功能设置") == "Features")
        #expect(L10n.text("设置…") == "Settings…")
        #expect(L10n.text("拖入文件或文件夹") == "Drop files or folders here")
        #expect(L10n.fileCount(1) == "1 file")
        #expect(L10n.fileCount(4) == "4 files")
        #expect(HotKeyShortcut.standard.label == "⌃⌥Space")
        L10n.configure(.chinese)
        #expect(L10n.text("功能设置") == "功能设置")
        #expect(L10n.fileCount(4) == "4 个文件")
        #expect(HotKeyShortcut.standard.label == "⌃⌥空格")
        L10n.configure(.system, preferredLanguages: ["en-US"])
        #expect(L10n.text("通用设置") == "General")
        #expect(L10n.text("开机自启动") == "Launch at Login")
        L10n.configure(.system, preferredLanguages: ["zh-Hans"])
        #expect(L10n.text("通用设置") == "通用设置")
    }

    @Test func launchAtLoginUsesSystemStatusAndRollsBackAfterErrors() {
        let loginItem = LoginItemStub(status: .disabled)
        let coordinator = AppCoordinator(launchAtLogin: loginItem)
        #expect(!coordinator.launchAtLoginEnabled)

        coordinator.setLaunchAtLoginEnabled(true)
        #expect(coordinator.launchAtLoginEnabled)
        #expect(coordinator.launchAtLoginMessage == nil)

        loginItem.status = .requiresApproval
        coordinator.refreshLaunchAtLoginStatus()
        #expect(coordinator.launchAtLoginEnabled)
        #expect(coordinator.launchAtLoginNeedsApproval)
        #expect(coordinator.launchAtLoginMessage != nil)
        coordinator.openLoginItemsSettings()
        #expect(loginItem.openedSystemSettings)

        loginItem.status = .disabled
        loginItem.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Denied"])
        coordinator.setLaunchAtLoginEnabled(true)
        #expect(!coordinator.launchAtLoginEnabled)
        #expect(coordinator.launchAtLoginMessage?.contains("Denied") == true)
    }
}
