import AppKit
import Foundation
import ServiceManagement

/// UserDefaults 封装。设置窗口与监听/清理逻辑共用。
enum AppSettings {
    private static let defaults = UserDefaults.standard

    enum AppearanceMode: String {
        case system, light, dark
    }

    /// 界面语言：跟随系统 / 简体中文 / English。切换即时生效（刷新 Loc 缓存 + 发通知，AppKit 与 SwiftUI 各自重绘）。
    enum Language: String, CaseIterable {
        case system, zh, en
    }

    /// 主面板玻璃风格预设：一套 (毛玻璃材质 + 着色 + 强制外观 + 亮边强度) 组合。standard = 现状默认。
    /// 前四档是纯玻璃；cream=暖奶油着色玻璃；pureWhite/pureBlack=不透明纯色底（强制外观保证文字对比）。
    enum GlassStyle: String {
        case airy, standard, rich, minimal, cream, pureWhite, pureBlack

        /// 主面板毛玻璃材质（纯色档底下的玻璃会被不透明着色层盖住，取 .menu 即可）
        var material: NSVisualEffectView.Material {
            switch self {
            case .airy: return .popover
            case .standard: return .menu
            case .rich: return .sidebar
            case .minimal: return .underWindowBackground
            case .cream, .pureWhite, .pureBlack: return .menu
            }
        }

        /// 叠在毛玻璃之上、内容之下的着色层。nil = 纯玻璃不着色；
        /// alpha<1 = 半透明暖玻璃着色；alpha=1 = 不透明纯色底。
        var tintColor: NSColor? {
            switch self {
            case .airy, .standard, .rich, .minimal: return nil
            case .cream:     return NSColor(srgbRed: 0.945, green: 0.898, blue: 0.831, alpha: 0.55) // 暖奶油
            case .pureWhite:  return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            case .pureBlack:  return NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
            }
        }

        /// 强制面板外观以保证前景文字对比；nil = 跟随系统/用户外观设置。
        /// cream/pureWhite 强制浅色（文字变深）、pureBlack 强制深色（文字变浅）。
        var forcedAppearance: NSAppearance.Name? {
            switch self {
            case .airy, .standard, .rich, .minimal: return nil
            case .cream, .pureWhite: return .aqua
            case .pureBlack: return .darkAqua
            }
        }

        /// 面板亮边 + 顶部高光的强度倍率（1.0 = 标准，不变）
        var chromeScale: CGFloat {
            switch self {
            case .airy: return 0.7
            case .standard: return 1.0
            case .rich: return 1.15
            case .minimal: return 0.5
            case .cream: return 0.8
            case .pureWhite: return 0.6
            case .pureBlack: return 0.7
            }
        }
    }

    private enum Key {
        static let ignoreImages = "ignoreImages"
        static let ignoreFiles = "ignoreFiles"
        static let ignoreLargeContent = "ignoreLargeContent"
        static let maxContentSizeMB = "maxContentSizeMB"
        static let autoCleanupEnabled = "autoCleanupEnabled"
        static let retentionDays = "retentionDays"
        static let appearanceMode = "appearanceMode"
        static let glassStyle = "glassStyle"
        static let language = "appLanguage"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.ignoreImages: false,
            Key.ignoreFiles: false,
            Key.ignoreLargeContent: true,
            Key.maxContentSizeMB: 1.0,
            Key.autoCleanupEnabled: false,
            Key.retentionDays: 7,
            Key.appearanceMode: AppearanceMode.system.rawValue,
            Key.glassStyle: GlassStyle.standard.rawValue,
            Key.language: Language.system.rawValue,
        ])
    }

    /// 界面语言：跟随系统 / 简体中文 / English。写入后刷新 Loc 缓存并广播，全 App 即时切换。
    static var language: Language {
        get { Language(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: Key.language)
            Loc.refresh()
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }

    /// 外观：跟随系统 / 浅色 / 深色，作用于整个 App（NSApp.appearance）
    static var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Key.appearanceMode) ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appearanceMode)
            applyAppearance()
        }
    }

    static func applyAppearance() {
        switch appearanceMode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 玻璃风格：作用于主面板毛玻璃材质与亮边强度（Toast 提示不联动）
    static var glassStyle: GlassStyle {
        get { GlassStyle(rawValue: defaults.string(forKey: Key.glassStyle) ?? "") ?? .standard }
        set {
            defaults.set(newValue.rawValue, forKey: Key.glassStyle)
            applyGlassStyle()
        }
    }

    /// 广播玻璃风格变更，主面板监听后即时重绘（仿 .clipStoreDidChange 的通知派发）
    static func applyGlassStyle() {
        NotificationCenter.default.post(name: .glassStyleDidChange, object: nil)
    }

    static var ignoreImages: Bool {
        get { defaults.bool(forKey: Key.ignoreImages) }
        set { defaults.set(newValue, forKey: Key.ignoreImages) }
    }

    static var ignoreFiles: Bool {
        get { defaults.bool(forKey: Key.ignoreFiles) }
        set { defaults.set(newValue, forKey: Key.ignoreFiles) }
    }

    static var ignoreLargeContent: Bool {
        get { defaults.bool(forKey: Key.ignoreLargeContent) }
        set { defaults.set(newValue, forKey: Key.ignoreLargeContent) }
    }

    /// 忽略阈值（MB），默认 1
    static var maxContentSizeMB: Double {
        get { defaults.double(forKey: Key.maxContentSizeMB) }
        set { defaults.set(newValue, forKey: Key.maxContentSizeMB) }
    }

    static var maxContentSizeBytes: Int {
        Int(maxContentSizeMB * 1024 * 1024)
    }

    static var autoCleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.autoCleanupEnabled) }
        set { defaults.set(newValue, forKey: Key.autoCleanupEnabled) }
    }

    static var retentionDays: Int {
        get { max(1, defaults.integer(forKey: Key.retentionDays)) }
        set { defaults.set(max(1, newValue), forKey: Key.retentionDays) }
    }

    // MARK: - 开机自启（SMAppService）

    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("SMAppService failed: \(error)")
            return false
        }
    }
}

extension Notification.Name {
    /// 玻璃风格设置变更
    static let glassStyleDidChange = Notification.Name("glassStyleDidChange")
    /// 界面语言设置变更（AppKit 侧监听后即时重绘：分段标题、占位符、空态、状态栏菜单等）
    static let languageDidChange = Notification.Name("languageDidChange")
}

/// 运行时语言解析：把 AppSettings.language（含「跟随系统」）解析成具体的中/英，缓存以支撑高频调用。
enum Loc {
    /// 当前是否英文。首次访问即解析（此时 registerDefaults 已跑完）；语言变更时 refresh()。
    static private(set) var isEnglish: Bool = resolve()

    static func refresh() { isEnglish = resolve() }

    private static func resolve() -> Bool {
        switch AppSettings.language {
        case .en: return true
        case .zh: return false
        case .system:
            let pref = (Locale.preferredLanguages.first ?? "en").lowercased()
            return !pref.hasPrefix("zh")
        }
    }
}

/// 就地本地化：按当前语言返回中/英文案。翻译与调用点同处，从根上杜绝「漏键」。
/// - 注意：AppKit 侧取值发生在控件构建/刷新时，语言切换后须触发对应重绘才会更新（见 .languageDidChange 监听）。
func L(_ zh: String, _ en: String) -> String { Loc.isEnglish ? en : zh }
