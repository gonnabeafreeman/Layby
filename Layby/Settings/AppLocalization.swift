import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case chinese = "zh-Hans"
    var id: Self { self }

    func resolved(preferredLanguages: [String]) -> Self {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let code = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") { return .chinese }
            if code == "en" || code.hasPrefix("en-") { return .english }
        }
        return .english
    }

    @MainActor var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .english: "English"
        case .chinese: "中文"
        }
    }
}

/// An observable, in-process language choice updates SwiftUI and AppKit without restarting.
@Observable @MainActor
final class L10n {
    private static let shared = L10n()
    private var language: AppLanguage = .system
    private var preferredLanguages = Locale.preferredLanguages
    private var resolved: AppLanguage { language.resolved(preferredLanguages: preferredLanguages) }

    @discardableResult static func configure(_ language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> Bool {
        let previous = shared.resolved
        if shared.language != language { shared.language = language }
        if shared.preferredLanguages != preferredLanguages { shared.preferredLanguages = preferredLanguages }
        return previous != shared.resolved
    }

    static func text(_ key: String) -> String {
        shared.resolved == .chinese ? key : (english[key] ?? key)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: shared.resolved.rawValue), arguments: arguments)
    }

    static func fileCount(_ count: Int) -> String {
        count == 1 ? text("1 个文件") : format("%d 个文件", count)
    }

    private static let english: [String: String] = [
        "关于": "About", "当前版本": "Version", "未知版本": "Unknown version",
        "给待会还会用到的文件，一个随手可取的地方。": "A handy place for files you’ll need in a moment.",
        "支持 Layby": "Support Layby", "给 Layby 一颗 Star": "Star Layby on GitHub",
        "如果 Layby 对你有帮助，欢迎在 GitHub 上点一颗 Star，支持项目继续成长。": "Enjoying Layby? Give it a star on GitHub to support the project’s growth.",
        "在 GitHub 上点一颗 Star": "Give it a star on GitHub",
        "没有适用的文件服务": "No Applicable File Services", "正在读取文件服务…": "Loading File Services…",
        "无法执行文件服务“%@”，请确认提供该服务的应用可用。": "Could not run file service “%@”. Check that its provider is available.",
        "没有适用的服务": "No Applicable Services", "服务": "Services",
        "对全部文件执行更多操作": "More Actions for All Files",
        "文件不可用，请重新检查后再使用服务": "File unavailable. Recheck it before using Services.",
        "已固定在屏幕顶部中央；单击切换大小，用力拖离可解除固定": "Docked at the top center of the display; click to resize, pull away to undock",
        "功能设置": "Features", "通用设置": "General", "设置": "Settings", "设置…": "Settings…",
        "Layby 设置": "Layby Settings", "跟随系统": "Follow System", "语言": "Language", "检查更新…": "Check for Updates…",
        "在菜单栏显示": "Show in menu bar", "自动检查更新": "Automatically check for updates",
        "选择应用的显示语言，更改后立即生效。": "Choose the app language. Changes apply immediately.",
        "呼出方式": "Activation Methods", "选择习惯的方式，随时唤出 Layby。": "Choose how you bring up Layby.",
        "摇晃文件": "Shake a file", "拖拽文件时摇晃鼠标，即可呼出停放区。": "Shake the pointer while dragging a file to show the shelf.",
        "摇晃幅度": "Shake intensity", "轻轻摇晃": "Gentle", "适中": "Balanced", "用力摇晃": "Deliberate",
        "按住修饰键并拖拽": "Hold a modifier while dragging", "修饰键": "Modifier key",
        "先按住修饰键再拖拽，或拖拽途中按住，都可以呼出。": "Hold the modifier before or during a file drag to show the shelf.",
        "拖到刘海区域": "Drag to the notch", "无刘海时使用屏幕顶部中央": "Use the top center on displays without a notch",
        "全局快捷键": "Global Shortcut", "启用快捷键": "Enable shortcut", "新建停放区": "New Shelf",
        "点击键位后按下新组合键，Esc 取消。": "Click the shortcut, then press a new combination. Esc cancels.",
        "兼容性": "Compatibility", "已识别的拖拽": "Detected drags", "%d 次": "%d",
        "辅助功能访问": "Accessibility access", "已允许": "Allowed", "未允许": "Not allowed",
        "若在其他应用中摇晃无反应，可在系统设置中允许辅助功能访问。": "If shaking in other apps does not work, allow Accessibility access in System Settings.",
        "打开辅助功能设置": "Open Accessibility Settings", "重新检查": "Check Again",
        "按下组合键…": "Press shortcut…", "请包含修饰键": "Include a modifier", "空格": "Space",
        "快捷键无法注册（%d），请更换组合键。": "Could not register shortcut (%d). Choose another combination.",
        "该组合键不可用（%d），已保留原快捷键。": "Shortcut unavailable (%d). Your previous shortcut was kept.",
        "退出 Layby": "Quit Layby", "编辑": "Edit", "剪切": "Cut", "复制": "Copy", "粘贴": "Paste", "全选": "Select All",
        "Layby 文件停放区": "Layby File Shelf", "Layby — 临时文件停放区": "Layby — Temporary File Shelf",
        "1 个文件": "1 file", "%d 个文件": "%d files", "正在接收 %d 个文件…": "Receiving %d files…",
        "%d 个文件不可用": "%d files unavailable", "拖动单个文件以取出": "Drag a file to take it out",
        "返回文件堆叠": "Back to Stack", "关闭并清空停放区": "Close and Clear Shelf", "缩略图网格": "Thumbnail Grid",
        "文件列表": "File List", "展开文件列表": "Expand Files", "松手，放在这里": "Release to drop here",
        "拖入文件或文件夹": "Drop files or folders here",
        "接收完成后可整体拖出；可展开列表处理不可用文件": "Drag the stack once all files are ready, or expand to manage unavailable files",
        "拖动堆叠，取出全部文件": "Drag the stack to take out all files",
        "文件堆叠，%@，拖动以取出全部文件": "File stack, %@. Drag to take out all files",
        "展开，查看和拖出单个文件": "Expand to view and drag individual files", "查看全部 %@": "View all %@",
        "%@，%@，拖动以取出此文件": "%@, %@. Drag to take out this file",
        "在 Finder 中显示": "Reveal in Finder", "从停放区移除": "Remove from Shelf", "清空停放区": "Clear Shelf",
        "快速查看": "Quick Look", "隔空投送": "AirDrop", "邮件": "Mail", "信息": "Messages",
        "备忘录": "Notes", "提醒事项": "Reminders", "用…打开": "Open With…", "其他…": "Other…", "打开": "Open",
        "当前无法使用该功能": "This action isn't available right now",
        "打开文件夹": "Open Folder", "返回上一层": "Back to Parent",
        "正在读取文件夹…": "Reading folder…", "此文件夹为空": "This folder is empty",
        "无法读取文件夹，请检查文件是否存在及访问权限。": "Cannot read this folder. Check that it exists and you have access.",
        "已选择 %d 个文件 · %@": "%d selected · %@", "大小未知": "Size unknown",
        "正在接收": "Receiving", "文件不可用": "File unavailable", "文件夹": "Folder", "正在读取…": "Reading…",
        "正在接收文件": "Receiving file", "等待来源应用…": "Waiting for source app…", "无法访问": "Unavailable",
        "接收失败": "Transfer failed", "接收超时": "Transfer timed out",
        "已加入支持的文件，其他内容已跳过。": "Supported files added. Other content was skipped.",
        "已复制 %d 个文件": "Copied %d files",
        "部分文件未能接收，请从来源应用重新拖入。": "Some files could not be received. Drag them again from the source app.",
        "无法创建临时接收目录，请稍后重试。": "Could not create a temporary folder. Please try again.",
        "移动停放区": "Move Shelf", "按住顶部横条并拖动，可以移动窗口": "Hold and drag the top handle to move the window",
        "暂放到 Layby": "Drop into Layby",
        "收起为迷你胶囊": "Collapse to Capsule", "展开停放区": "Expand Shelf",
        "展开停放区，%@": "Expand shelf, %@",
        "单击收起为胶囊，拖动可移动停放区": "Click to collapse; drag to move the shelf",
        "单击展开停放区，拖动可移动胶囊": "Click to expand; drag to move the capsule",
        "按住把手并拖动，可以移动胶囊": "Hold and drag the handle to move the capsule"
    ]
}
