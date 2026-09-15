import AppKit
import Carbon
import Observation

enum DragModifier: String, CaseIterable, Identifiable {
    case shift, option, control, command
    var id: Self { self }
    var title: String {
        switch self { case .shift: "⇧ Shift"; case .option: "⌥ Option"; case .control: "⌃ Control"; case .command: "⌘ Command" }
    }
    var flag: NSEvent.ModifierFlags {
        switch self { case .shift: .shift; case .option: .option; case .control: .control; case .command: .command }
    }
}

struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    static let standard = Self(keyCode: 49, modifiers: UInt32(controlKey | optionKey), keyLabel: "空格")
    @MainActor var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + (keyCode == 49 ? L10n.text("空格") : keyLabel)
    }
    static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}

@Observable @MainActor
final class AppSettings {
    var language: AppLanguage { didSet { save() } }
    var shakeEnabled: Bool { didSet { save() } }
    var modifierEnabled: Bool { didSet { save() } }
    var notchEnabled: Bool { didSet { save() } }
    var topEdgeEnabled: Bool { didSet { save() } }
    var hotKeyEnabled: Bool { didSet { save() } }
    var menuBarEnabled: Bool { didSet { save() } }
    var automaticUpdateChecksEnabled: Bool { didSet { save() } }
    var sensitivity: ShakeSensitivity { didSet { save() } }
    var modifier: DragModifier { didSet { save() } }
    var shortcut: HotKeyShortcut { didSet { save() } }
    var excludedBundleIDs: String { didSet { save() } }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        defaults.register(defaults: ["shakeEnabled": true, "modifierEnabled": true,
                                    "notchEnabled": true, "hotKeyEnabled": true,
                                    "menuBarEnabled": true, "automaticUpdateChecksEnabled": true])
        shakeEnabled = defaults.bool(forKey: "shakeEnabled")
        modifierEnabled = defaults.bool(forKey: "modifierEnabled")
        notchEnabled = defaults.bool(forKey: "notchEnabled")
        topEdgeEnabled = defaults.bool(forKey: "topEdgeEnabled")
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
        menuBarEnabled = defaults.bool(forKey: "menuBarEnabled")
        automaticUpdateChecksEnabled = defaults.bool(forKey: "automaticUpdateChecksEnabled")
        sensitivity = ShakeSensitivity(rawValue: defaults.string(forKey: "sensitivity") ?? "") ?? .balanced
        modifier = DragModifier(rawValue: defaults.string(forKey: "modifier") ?? "") ?? .shift
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(HotKeyShortcut.self, from: $0) } ?? .standard
        excludedBundleIDs = defaults.string(forKey: "excludedBundleIDs") ?? ""
    }

    func excludes(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.split(whereSeparator: { $0.isWhitespace || $0 == "," }).contains { $0 == bundleID }
    }

    private func save() {
        defaults.set(language.rawValue, forKey: "language")
        defaults.set(shakeEnabled, forKey: "shakeEnabled")
        defaults.set(modifierEnabled, forKey: "modifierEnabled")
        defaults.set(notchEnabled, forKey: "notchEnabled")
        defaults.set(topEdgeEnabled, forKey: "topEdgeEnabled")
        defaults.set(hotKeyEnabled, forKey: "hotKeyEnabled")
        defaults.set(menuBarEnabled, forKey: "menuBarEnabled")
        defaults.set(automaticUpdateChecksEnabled, forKey: "automaticUpdateChecksEnabled")
        defaults.set(sensitivity.rawValue, forKey: "sensitivity")
        defaults.set(modifier.rawValue, forKey: "modifier")
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut")
        defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs")
        onChange?()
    }
}
