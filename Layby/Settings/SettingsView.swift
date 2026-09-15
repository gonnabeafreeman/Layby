import AppKit
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case features, general, about
    var id: Self { self }
    var title: String {
        switch self {
        case .features: "功能设置"
        case .general: "通用设置"
        case .about: "关于"
        }
    }
    var symbol: String {
        switch self {
        case .features: "slider.horizontal.3"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let coordinator: AppCoordinator
    // Explicit DynamicProperty storage also supports the CLT SDK without State macros.
    private var page = State<SettingsPage?>(initialValue: .features)
    private var selectedPage: SettingsPage { page.wrappedValue ?? .features }

    init(settings: AppSettings, coordinator: AppCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Layby").font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 18).padding(.top, 22)
                List(selection: page.projectedValue) {
                    ForEach(SettingsPage.allCases) { page in
                        Label(L10n.text(page.title), systemImage: page.symbol)
                            .padding(.vertical, 5).tag(page)
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            .frame(width: 180)
            .frame(maxHeight: .infinity)
            // Extend only the material behind the traffic lights; sidebar
            // content keeps the title-bar safe area and remains below them.
            .background(.regularMaterial, ignoresSafeAreaEdges: .vertical)
            Divider().ignoresSafeArea(.container, edges: .vertical)
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text(selectedPage.title)).font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
                switch selectedPage {
                case .features: featureSettings
                case .general: generalSettings
                case .about: aboutSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: .vertical)
        }
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private var featureSettings: some View {
        Form {
            Section {
                Toggle(L10n.text("摇晃文件"), isOn: $settings.shakeEnabled)
                Picker(L10n.text("摇晃幅度"), selection: $settings.sensitivity) {
                    ForEach(ShakeSensitivity.allCases) { Text(L10n.text($0.title)).tag($0) }
                }.disabled(!settings.shakeEnabled)
                Toggle(L10n.text("按住修饰键并拖拽"), isOn: $settings.modifierEnabled)
                Picker(L10n.text("修饰键"), selection: $settings.modifier) {
                    ForEach(DragModifier.allCases) { Text($0.title).tag($0) }
                }.disabled(!settings.modifierEnabled)
                Toggle(L10n.text("拖到刘海区域"), isOn: $settings.notchEnabled)
                Toggle(L10n.text("无刘海时使用屏幕顶部中央"), isOn: $settings.topEdgeEnabled)
                    .disabled(!settings.notchEnabled)
            } header: {
                Text(L10n.text("呼出方式"))
            } footer: {
                Text(L10n.text("先按住修饰键再拖拽，或拖拽途中按住，都可以呼出。"))
            }
            Section {
                Toggle(L10n.text("启用快捷键"), isOn: $settings.hotKeyEnabled)
                HStack {
                    Text(L10n.text("新建停放区"))
                    Spacer()
                    ShortcutRecorder(shortcut: settings.shortcut) { coordinator.changeShortcut($0) }
                        .frame(width: 160, height: 28).disabled(!settings.hotKeyEnabled)
                }
                if let message = coordinator.hotKeyMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text(L10n.text("全局快捷键"))
            } footer: {
                Text(L10n.text("点击键位后按下新组合键，Esc 取消。"))
            }
            Section {
                LabeledContent(L10n.text("已识别的拖拽"), value: L10n.format("%d 次", coordinator.observation.observedDragCount))
                LabeledContent(L10n.text("辅助功能访问"), value: L10n.text(coordinator.observation.hasAccessibilityTrust ? "已允许" : "未允许"))
                Text(L10n.text("若在其他应用中摇晃无反应，可在系统设置中允许辅助功能访问。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text("打开辅助功能设置")) { coordinator.openAccessibilitySettings() }
                    Button(L10n.text("重新检查")) { coordinator.refreshObservation() }
                }
            } header: {
                Text(L10n.text("兼容性"))
            }
        }
        .formStyle(.grouped)
    }

    private var aboutSettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Layby").font(.system(size: 28, weight: .semibold))
                    Text(L10n.text("给待会还会用到的文件，一个随手可取的地方。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
                LabeledContent(L10n.text("当前版本"), value: AppInfo.version)
                Button(L10n.text("检查更新…")) { coordinator.checkForUpdates() }
            }
            Section {
                HStack(alignment: .top, spacing: 16) {
                    Image("GitHubMark")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .frame(width: 48, height: 48)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("支持 Layby"))
                            .font(.headline)
                        Text(supportDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .tint(.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var supportDescription: AttributedString {
        var text = AttributedString(L10n.text("如果 Layby 对你有帮助，欢迎在 GitHub 上点一颗 Star，支持项目继续成长。"))
        if let range = text.range(of: L10n.text("在 GitHub 上点一颗 Star")) {
            text[range].link = AppInfo.repositoryURL
        }
        return text
    }

    private var generalSettings: some View {
        Form {
            Section {
                Picker(L10n.text("语言"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle(L10n.text("在菜单栏显示"), isOn: $settings.menuBarEnabled)
                Toggle(L10n.text("自动检查更新"), isOn: $settings.automaticUpdateChecksEnabled)
            } footer: {
                Text(L10n.text("选择应用的显示语言，更改后立即生效。"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: HotKeyShortcut
    let onChange: (HotKeyShortcut) -> Void
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        button.onChange = onChange
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.shortcut = shortcut
        button.onChange = onChange
        if !button.recording { button.title = shortcut.label }
    }
}

@MainActor
private final class ShortcutButton: NSButton {
    var shortcut = HotKeyShortcut.standard
    var onChange: ((HotKeyShortcut) -> Void)?
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        recording = true
        title = L10n.text("按下组合键…")
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        if !recording { recording = true; title = L10n.text("按下组合键…"); return }
        if event.keyCode == 53 { finish(); return }
        let flags = HotKeyShortcut.carbonFlags(event.modifierFlags)
        guard flags != 0, let character = event.charactersIgnoringModifiers, !character.isEmpty else {
            title = L10n.text("请包含修饰键"); return
        }
        let label = event.keyCode == 49 ? "Space" : character.uppercased()
        onChange?(HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: flags, keyLabel: label))
        finish()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    private func finish() { recording = false; title = shortcut.label }
}
