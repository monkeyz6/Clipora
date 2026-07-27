import Combine
import KeyboardShortcuts
import SwiftUI

// MARK: - 语言管理（SwiftUI 侧实时重渲染）

/// 设置页各 View 监听它；`set` 写库后同时 republish，驱动整棵设置界面按新语言重绘。
/// AppKit 侧由 AppSettings.language 的 .languageDidChange 通知负责刷新。
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    @Published var language: AppSettings.Language = AppSettings.language
    private init() {}

    func set(_ lang: AppSettings.Language) {
        guard lang != language else { return }
        AppSettings.language = lang   // 持久化 + 刷新 Loc 缓存 + 通知 AppKit
        language = lang               // 触发 SwiftUI 重渲染
    }
}

// MARK: - 设计 token（源自设计稿，跟随浅色/深色）

private struct DS {
    let dark: Bool
    private func rgb(_ r: Double, _ g: Double, _ b: Double, _ o: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: o)
    }
    private func white(_ o: Double) -> Color { Color(.sRGB, white: 1, opacity: o) }

    var fg: Color { dark ? white(0.92) : rgb(29, 29, 31) }
    var sub: Color { dark ? white(0.5) : rgb(60, 60, 67, 0.6) }
    var faint: Color { dark ? white(0.32) : rgb(60, 60, 67, 0.42) }
    var accent: Color { rgb(42, 111, 219) }                    // #2A6FDB

    var toggleOff: Color { dark ? white(0.16) : rgb(120, 120, 128, 0.24) }
    var cardBg: Color { dark ? white(0.06) : white(0.55) }
    var cardRing: Color { dark ? white(0.07) : white(0.6) }

    var controlBg: Color { dark ? white(0.1) : white(1) }      // 下拉/步进器/键帽底
    var controlRing: Color { dark ? white(0.08) : rgb(0, 0, 20, 0.06) }
    var kbdRing: Color { dark ? white(0.1) : rgb(0, 0, 20, 0.08) }
    var divider: Color { dark ? white(0.08) : rgb(0, 0, 20, 0.07) }

    var tabsWrapBg: Color { dark ? white(0.08) : rgb(120, 120, 128, 0.14) }
    var tabOnBg: Color { dark ? white(0.16) : white(1) }
    var softKbdBg: Color { dark ? white(0.05) : rgb(120, 120, 128, 0.1) }

    var dangerFg: Color { dark ? rgb(255, 138, 128) : rgb(208, 52, 44) }
    var dangerBg: Color { dark ? rgb(255, 90, 80, 0.14) : rgb(255, 90, 80, 0.1) }
    var dangerRing: Color { dark ? rgb(255, 90, 80, 0.25) : rgb(255, 90, 80, 0.2) }

    var knobShadow: Color { rgb(0, 0, 20, 0.3) }
}

// MARK: - 根视图

struct SettingsView: View {
    @ObservedObject private var loc = LocalizationManager.shared
    @Environment(\.colorScheme) private var scheme
    fileprivate enum Tab { case general, help }
    @State private var tab: Tab = .general

    /// 仅供离屏预览：撑高窗口以在无滚动的情况下截到全部内容
    private var previewHeight: CGFloat? = nil

    init() {}
    #if DEBUG
    fileprivate init(previewHeight: CGFloat, tab: Tab) {
        self.previewHeight = previewHeight
        _tab = State(initialValue: tab)
    }
    #endif

    var body: some View {
        let ds = DS(dark: scheme == .dark)
        VStack(spacing: 0) {
            // 标题栏：原生红绿灯浮于左上，此处仅居中标题（与设计稿一致）
            Text(L("Clipora 设置", "Clipora Settings"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ds.sub)
                .frame(maxWidth: .infinity)
                .frame(height: 44)

            // 分段切换
            SegTabs(
                ds: ds,
                isSettings: Binding(get: { tab == .general }, set: { tab = $0 ? .general : .help }),
                settingsLabel: L("设置", "Settings"),
                helpLabel: L("帮助", "Help")
            )
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                Group {
                    switch tab {
                    case .general: GeneralSettingsView(ds: ds)
                    case .help: HelpView(ds: ds)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(width: 480, height: previewHeight ?? 640, alignment: .top)
        .background(Color.clear)
        // fullSizeContentView 下 SwiftUI 会自动内缩一段标题栏安全区；忽略它，
        // 让 44px 标题带与原生红绿灯并排在同一行（对齐设计稿），消除顶部双层空隙。
        .ignoresSafeArea()
    }
}

// MARK: - 设置页

private struct GeneralSettingsView: View {
    let ds: DS

    @ObservedObject private var loc = LocalizationManager.shared

    @AppStorage("ignoreImages") private var ignoreImages = false
    @AppStorage("ignoreFiles") private var ignoreFiles = false
    @AppStorage("ignoreLargeContent") private var ignoreLargeContent = true
    @AppStorage("maxContentSizeMB") private var maxContentSizeMB = 1.0
    @AppStorage("autoCleanupEnabled") private var autoCleanupEnabled = false
    @AppStorage("retentionDays") private var retentionDays = 7
    @AppStorage("historyLimit") private var historyLimit = 500
    @AppStorage("searchByRelevance") private var searchByRelevance = true
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppSettings.AppearanceMode.system.rawValue
    @AppStorage("glassStyle") private var glassStyleRaw = AppSettings.GlassStyle.standard.rawValue

    @State private var launchAtLogin = AppSettings.launchAtLogin
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            general
            ignoreSection
            cleanupSection
            shortcutsSection
        }
    }

    // MARK: 通用

    private var general: some View {
        section(L("通用", "General")) {
            SettingsCard(ds: ds) {
                row {
                    Text(L("开机时自动启动", "Launch at login")).settingLabel(ds)
                    Spacer(minLength: 16)
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(AppleToggleStyle(ds: ds))
                        .onChange(of: launchAtLogin) { _, newValue in
                            if !AppSettings.setLaunchAtLogin(newValue) {
                                launchAtLogin = AppSettings.launchAtLogin
                            }
                        }
                }
                CardDivider(ds: ds)
                row {
                    Text(L("外观", "Appearance")).settingLabel(ds)
                    Spacer(minLength: 16)
                    DropdownButton(ds: ds, label: appearanceLabel) {
                        button(L("跟随系统", "System"), .system, $appearanceModeRaw) { apply in
                            appearanceModeRaw = apply; AppSettings.applyAppearance()
                        }
                        button(L("浅色", "Light"), .light, $appearanceModeRaw) { apply in
                            appearanceModeRaw = apply; AppSettings.applyAppearance()
                        }
                        button(L("深色", "Dark"), .dark, $appearanceModeRaw) { apply in
                            appearanceModeRaw = apply; AppSettings.applyAppearance()
                        }
                    }
                }
                CardDivider(ds: ds)
                row {
                    Text(L("玻璃风格", "Glass style")).settingLabel(ds)
                    Spacer(minLength: 16)
                    DropdownButton(ds: ds, label: glassLabel) {
                        glassButton(L("清透", "Airy"), .airy)
                        glassButton(L("标准磨砂", "Standard"), .standard)
                        glassButton(L("浓郁", "Rich"), .rich)
                        glassButton(L("极简", "Minimal"), .minimal)
                        Divider()
                        glassButton("Cream", .cream)
                        glassButton(L("纯白", "Pure white"), .pureWhite)
                        glassButton(L("纯黑", "Pure black"), .pureBlack)
                    }
                }
                CardDivider(ds: ds)
                row {
                    Text(L("语言", "Language")).settingLabel(ds)
                    Spacer(minLength: 16)
                    DropdownButton(ds: ds, label: languageLabel) {
                        Button(L("跟随系统", "System")) { loc.set(.system) }
                        Button("简体中文") { loc.set(.zh) }
                        Button("English") { loc.set(.en) }
                    }
                }
                CardDivider(ds: ds)
                row {
                    Text(L("搜索结果排序", "Search result order")).settingLabel(ds)
                    Spacer(minLength: 16)
                    DropdownButton(
                        ds: ds,
                        label: searchByRelevance
                            ? L("按相关度", "By relevance")
                            : L("按时间", "By time")
                    ) {
                        Button(L("按相关度", "By relevance")) { searchByRelevance = true }
                        Button(L("按时间", "By time")) { searchByRelevance = false }
                    }
                }
            }
        }
    }

    // MARK: 复制时忽略

    private var ignoreSection: some View {
        section(L("复制时忽略", "Ignore when copying")) {
            SettingsCard(ds: ds) {
                row {
                    Text(L("忽略图片", "Ignore images")).settingLabel(ds)
                    Spacer(minLength: 16)
                    toggle($ignoreImages)
                }
                CardDivider(ds: ds)
                row {
                    Text(L("忽略文件", "Ignore files")).settingLabel(ds)
                    Spacer(minLength: 16)
                    toggle($ignoreFiles)
                }
                CardDivider(ds: ds)
                row {
                    Text(L("忽略过大的内容", "Ignore oversized content")).settingLabel(ds)
                    Spacer(minLength: 16)
                    toggle($ignoreLargeContent)
                }
                CardDivider(ds: ds)
                row {
                    (Text(L("大于 ", "Content over ")).foregroundColor(ds.sub)
                        + Text("\(Int(maxContentSizeMB.rounded()))").fontWeight(.semibold).foregroundColor(ds.fg)
                        + Text(L(" MB 的内容不记录", " MB won't be recorded")).foregroundColor(ds.sub))
                        .font(.system(size: 14.5))
                    Spacer(minLength: 16)
                    StepperControl(
                        ds: ds,
                        onMinus: { maxContentSizeMB = max(1, maxContentSizeMB.rounded() - 1) },
                        onPlus: { maxContentSizeMB = min(999, maxContentSizeMB.rounded() + 1) }
                    )
                }
            }
        }
    }

    // MARK: 自动清理

    private var cleanupSection: some View {
        section(L("自动清理", "Auto cleanup")) {
            SettingsCard(ds: ds) {
                row {
                    Text(L("自动清理历史", "Auto-clean history")).settingLabel(ds)
                    Spacer(minLength: 16)
                    toggle($autoCleanupEnabled)
                }
                CardDivider(ds: ds)
                row {
                    (Text(L("保留最近 ", "Keep the last ")).foregroundColor(ds.fg)
                        + Text("\(retentionDays)").fontWeight(.semibold).foregroundColor(ds.fg)
                        + Text(L(" 天", " days")).foregroundColor(ds.fg))
                        .font(.system(size: 14.5))
                    Spacer(minLength: 16)
                    StepperControl(
                        ds: ds,
                        onMinus: { retentionDays = max(1, retentionDays - 1) },
                        onPlus: { retentionDays = min(365, retentionDays + 1) }
                    )
                }
                CardDivider(ds: ds)
                row {
                    (Text(L("最多保留 ", "Keep at most ")).foregroundColor(ds.fg)
                        + Text("\(historyLimit)").fontWeight(.semibold).foregroundColor(ds.fg)
                        + Text(L(" 条历史", " items")).foregroundColor(ds.fg))
                        .font(.system(size: 14.5))
                    Spacer(minLength: 16)
                    DropdownButton(ds: ds, label: "\(historyLimit)") {
                        Button("500") { historyLimit = 500 }
                        Button("1000") { historyLimit = 1000 }
                        Button("5000") { historyLimit = 5000 }
                        Button("10000") { historyLimit = 10000 }
                        Button("50000") { historyLimit = 50000 }
                    }
                    .onChange(of: historyLimit) { oldValue, newValue in
                        // 调低上限立即生效（后台裁剪），而不是等下一次复制才触发；
                        // 调高无需裁剪，跳过空写事务与多余的变更广播
                        if newValue < oldValue {
                            DatabaseManager.shared.trimHistoryToLimit()
                        }
                    }
                    .onAppear {
                        // 外部改写（defaults write）越界值时，把显示对齐到实际生效的钳制值
                        historyLimit = AppSettings.historyLimit
                    }
                }
            }
            Text(L("收藏的条目永不清理", "Favorites are never cleaned up"))
                .font(.system(size: 12))
                .foregroundColor(ds.faint)
                .padding(.leading, 4)

            DangerActionButton(ds: ds, title: L("立即清除历史…", "Clear history now…")) {
                showClearConfirm = true
            }
            .confirmationDialog(
                L("确定要清空全部历史记录吗？", "Clear all history?"),
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button(L("清空非收藏历史", "Clear non-favorite history"), role: .destructive) {
                    DatabaseManager.shared.clearNonFavorites()
                }
                Button(L("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(L("收藏的条目会保留，此操作不可撤销。", "Favorites are kept. This can't be undone."))
            }
        }
    }

    // MARK: 快捷键（设计稿未画，但功能保留，套用同款卡片样式）

    private var shortcutsSection: some View {
        section(L("快捷键", "Shortcuts")) {
            SettingsCard(ds: ds) {
                row {
                    Text(L("呼出剪贴历史", "Show clipboard history")).settingLabel(ds)
                    Spacer(minLength: 16)
                    KeyboardShortcuts.Recorder("", name: .toggleHistoryPanel)
                }
                CardDivider(ds: ds)
                row {
                    Text(L("呼出收藏", "Show favorites")).settingLabel(ds)
                    Spacer(minLength: 16)
                    KeyboardShortcuts.Recorder("", name: .toggleFavoritesPanel)
                }
            }
        }
    }

    // MARK: 组装辅助

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).labelsHidden().toggleStyle(AppleToggleStyle(ds: ds))
    }

    /// 外观下拉的单个选项（选中后回调应用）
    private func button(
        _ title: String, _ mode: AppSettings.AppearanceMode,
        _ raw: Binding<String>, _ apply: @escaping (String) -> Void
    ) -> some View {
        Button(title) { apply(mode.rawValue) }
    }

    private func glassButton(_ title: String, _ style: AppSettings.GlassStyle) -> some View {
        Button(title) { glassStyleRaw = style.rawValue; AppSettings.applyGlassStyle() }
    }

    private var appearanceLabel: String {
        switch AppSettings.AppearanceMode(rawValue: appearanceModeRaw) ?? .system {
        case .system: return L("跟随系统", "System")
        case .light: return L("浅色", "Light")
        case .dark: return L("深色", "Dark")
        }
    }

    private var glassLabel: String {
        switch AppSettings.GlassStyle(rawValue: glassStyleRaw) ?? .standard {
        case .airy: return L("清透", "Airy")
        case .standard: return L("标准磨砂", "Standard")
        case .rich: return L("浓郁", "Rich")
        case .minimal: return L("极简", "Minimal")
        case .cream: return "Cream"
        case .pureWhite: return L("纯白", "Pure white")
        case .pureBlack: return L("纯黑", "Pure black")
        }
    }

    private var languageLabel: String {
        switch loc.language {
        case .system: return L("跟随系统", "System")
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupLabel(ds: ds, text: title)
            content()
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

// MARK: - 帮助页（保留全部现有条目，套用设计稿卡片样式）

private struct HelpView: View {
    let ds: DS
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            group(L("呼出面板（全局）", "Show panel (global)"),
                  footnote: L("默认为 ⌘J 与 ⌘⇧J，可在「设置 › 快捷键」中自定义。",
                              "Defaults are ⌘J and ⌘⇧J; customize them under Settings › Shortcuts.")) {
                HelpRowView(ds: ds, tokens: [.text(historyShortcut)], desc: L("呼出剪贴历史", "Show clipboard history"))
                HelpRowView(ds: ds, tokens: [.text(favoritesShortcut)], desc: L("呼出收藏", "Show favorites"))
            }

            group(L("浏览与选择（面板打开时）", "Browse & select (panel open)")) {
                HelpRowView(ds: ds, tokens: [.gesture(L("直接输入", "Just type"))], desc: L("在当前列表中实时搜索", "Search the current list as you type"))
                HelpRowView(ds: ds, tokens: [.key("↑"), .key("↓")], desc: L("上下移动选择", "Move selection up / down"))
                HelpRowView(ds: ds, tokens: [.key("Tab")], desc: L("切换 历史 / 收藏", "Switch History / Favorites"))
                HelpRowView(ds: ds, tokens: [.key("↩")], desc: L("复制选中项并关闭面板", "Copy the selection and close the panel"))
                HelpRowView(ds: ds, tokens: [.key("esc")], desc: L("关闭面板", "Close the panel"))
            }

            group(L("对选中条目", "For the selected item")) {
                HelpRowView(ds: ds, tokens: [.key("⌘"), .key("D")], desc: L("收藏 / 取消收藏", "Favorite / unfavorite"))
                HelpRowView(ds: ds, tokens: [.key("⌘"), .key("⌫")], desc: L("删除（收藏页为移出收藏）", "Delete (removes from favorites on the Favorites tab)"))
                HelpRowView(ds: ds, tokens: [.key("→")], desc: L("历史页：收藏选中项", "History tab: favorite the selection"))
                HelpRowView(ds: ds, tokens: [.key("←")], desc: L("历史页：取消收藏", "History tab: unfavorite"))
                HelpRowView(ds: ds, tokens: [.key("←"), .key("→")], desc: L("收藏页：切换上一个 / 下一个分组", "Favorites tab: previous / next group"))
            }

            group(L("鼠标", "Mouse")) {
                HelpRowView(ds: ds, tokens: [.gesture(L("单击条目", "Click item"))], desc: L("复制并关闭面板", "Copy and close the panel"))
                HelpRowView(ds: ds, tokens: [.gesture(L("悬停条目", "Hover item"))], desc: L("选中该行并显示操作按钮", "Select the row and reveal action buttons"))
                HelpRowView(ds: ds, tokens: [.glyph("✎")], desc: L("重命名（只改显示，不改原文）", "Rename (display only, original text unchanged)"))
                HelpRowView(ds: ds, tokens: [.glyph("★")], desc: L("收藏 / 取消收藏（历史页）", "Favorite / unfavorite (History tab)"))
                HelpRowView(ds: ds, tokens: [.glyph("❏")], desc: L("移到分组（收藏页，已有分组时）", "Move to a group (Favorites tab, when groups exist)"))
                HelpRowView(ds: ds, tokens: [.glyph("✕")], desc: L("删除条目", "Delete item"))
                HelpRowView(ds: ds, tokens: [.gesture(L("拖动顶部空白", "Drag the top blank area"))], desc: L("移动面板位置（靠近默认位置会吸附）", "Move the panel (snaps near the default spot)"))
            }

            group(L("收藏与分组（收藏页）", "Favorites & groups (Favorites tab)")) {
                HelpRowView(ds: ds, tokens: [.gesture(L("拖动条目", "Drag item"))], desc: L("调整收藏排序（未搜索、「全部」分组时）", "Reorder favorites (when not searching, in the All group)"))
                HelpRowView(ds: ds, tokens: [.gesture(L("拖条目到胶囊", "Drag item onto a chip"))], desc: L("将条目归入该分组", "Add the item to that group"))
                HelpRowView(ds: ds, tokens: [.glyph("＋")], desc: L("新建分组", "New group"))
                HelpRowView(ds: ds, tokens: [.gesture(L("双击胶囊", "Double-click chip"))], desc: L("重命名分组", "Rename group"))
                HelpRowView(ds: ds, tokens: [.gesture(L("右键胶囊", "Right-click chip"))], desc: L("重命名 / 删除分组", "Rename / delete group"))
                HelpRowView(ds: ds, tokens: [.gesture(L("拖动胶囊", "Drag chip"))], desc: L("调整分组顺序", "Reorder groups"))
            }
        }
    }

    @ViewBuilder
    private func group<Content: View>(
        _ title: String, footnote: String? = nil, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupLabel(ds: ds, text: title)
            SettingsCard(ds: ds) {
                let rows = content()
                // 帮助行之间插入分隔线，交由各行自绘上边距即可；此处直接堆叠
                rows
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 12))
                    .foregroundColor(ds.faint)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var historyShortcut: String {
        KeyboardShortcuts.getShortcut(for: .toggleHistoryPanel)?.description ?? L("未设置", "Not set")
    }
    private var favoritesShortcut: String {
        KeyboardShortcuts.getShortcut(for: .toggleFavoritesPanel)?.description ?? L("未设置", "Not set")
    }
}

// MARK: - 复用组件

/// 分组标题（卡片上方的小标签）
private struct GroupLabel: View {
    let ds: DS
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .tracking(0.3)
            .foregroundColor(ds.faint)
            .padding(.leading, 4)
    }
}

/// 圆角半透明卡片容器
private struct SettingsCard<Content: View>: View {
    let ds: DS
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ds.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ds.cardRing, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 卡片内行分隔线（左侧 16 内缩）
private struct CardDivider: View {
    let ds: DS
    var body: some View {
        Rectangle().fill(ds.divider).frame(height: 0.5).padding(.leading, 16)
    }
}

/// iOS 风格开关（42×25，蓝色 accent，白色圆钮）
private struct AppleToggleStyle: ToggleStyle {
    let ds: DS
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return ZStack(alignment: on ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 99).fill(on ? ds.accent : ds.toggleOff)
            Circle()
                .fill(.white)
                .shadow(color: ds.knobShadow, radius: 1.5, x: 0, y: 1)
                .padding(2.5)
        }
        .frame(width: 42, height: 25)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
        .onTapGesture { configuration.isOn.toggle() }
    }
}

/// 自绘下拉：药丸样式 label + ⌄，菜单内容由调用方以 Button/Divider 提供
private struct DropdownButton<M: View>: View {
    let ds: DS
    let label: String
    @ViewBuilder var menu: () -> M
    var body: some View {
        Menu(content: menu) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 14, weight: .medium)).foregroundColor(ds.fg)
                Text("⌄").font(.system(size: 14)).foregroundColor(ds.sub).offset(y: -2)
            }
            .padding(.leading, 12)
            .padding(.trailing, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ds.controlBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ds.controlRing, lineWidth: 1))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// 步进器（− ＋）
private struct StepperControl: View {
    let ds: DS
    let onMinus: () -> Void
    let onPlus: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            btn("−", onMinus)
            btn("＋", onPlus)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ds.controlBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ds.controlRing, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    private func btn(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 15)).foregroundColor(ds.fg)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 危险操作按钮（红色）
private struct DangerActionButton: View {
    let ds: DS
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(ds.dangerFg)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ds.dangerBg))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(ds.dangerRing, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 顶部分段（设置 / 帮助）
private struct SegTabs: View {
    let ds: DS
    @Binding var isSettings: Bool
    let settingsLabel: String
    let helpLabel: String
    var body: some View {
        HStack(spacing: 2) {
            seg(settingsLabel, isSettings) { isSettings = true }
            seg(helpLabel, !isSettings) { isSettings = false }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ds.tabsWrapBg))
    }
    private func seg(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: on ? .semibold : .medium))
                .foregroundColor(on ? ds.fg : ds.sub)
                .padding(.horizontal, 20)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? ds.tabOnBg : Color.clear)
                        .shadow(color: on && !ds.dark ? ds.knobShadow.opacity(0.45) : .clear, radius: 1.5, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 帮助行

/// 帮助条目左侧的触发标记
private enum HelpToken: Hashable {
    case key(String)      // 键盘按键，硬键帽
    case glyph(String)    // 行内动作按钮字形（✎ ★ ❏ ✕ ＋），硬键帽
    case text(String)     // 现成组合键字符串（如 ⌘J），硬键帽
    case gesture(String)  // 鼠标 / 拖拽手势，软键帽
}

private struct HelpRowView: View {
    let ds: DS
    let tokens: [HelpToken]
    let desc: String
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 5) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    switch token {
                    case .key(let s), .text(let s), .glyph(let s):
                        KeyCapView(ds: ds, text: s, soft: false)
                    case .gesture(let s):
                        KeyCapView(ds: ds, text: s, soft: true)
                    }
                }
            }
            Text(desc)
                .font(.system(size: 14))
                .foregroundColor(ds.fg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// 键帽（硬：白底带边和阴影；软：浅灰底无边）
private struct KeyCapView: View {
    let ds: DS
    let text: String
    let soft: Bool
    var body: some View {
        Text(text)
            .font(.system(size: soft ? 12.5 : 14, weight: soft ? .regular : .medium))
            .monospacedDigit()
            .foregroundColor(soft ? ds.sub : ds.fg)
            .padding(.horizontal, soft ? 12 : 8)
            .frame(minWidth: soft ? 0 : 30, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(soft ? ds.softKbdBg : ds.controlBg)
                    .shadow(color: soft ? .clear : ds.knobShadow.opacity(0.4), radius: 1, y: 1)
            )
            .overlay(
                soft ? nil
                : RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ds.kbdRing, lineWidth: 1)
            )
    }
}

// MARK: - 行内文字修饰

private extension View {
    func settingLabel(_ ds: DS) -> some View {
        self.font(.system(size: 14.5)).foregroundColor(ds.fg)
    }
}

#if DEBUG
import AppKit

/// 离屏渲染设置页出图，仅供开发期核对外观（对齐既有 PanelPreviewRenderer）。
/// 由 `CLIPORA_SETTINGS_PREVIEW_DIR` 触发，渲染 中/英 × 浅/深 四张 PNG 后进程退出；
/// 不注册状态栏、不启监听、不动数据库；临时改动的语言用完即还原。
enum SettingsPreviewRenderer {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["CLIPORA_SETTINGS_PREVIEW_DIR"] else { return false }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let original = AppSettings.language
        defer { AppSettings.language = original }

        for (tag, lang) in [("zh", AppSettings.Language.zh), ("en", AppSettings.Language.en)] {
            AppSettings.language = lang                     // setter 内已 Loc.refresh()
            LocalizationManager.shared.language = lang
            for dark in [false, true] {
                write(render(dark: dark, view: SettingsView(), h: 640),
                      to: dir + "/settings-\(tag)-\(dark ? "dark" : "light").png")
                write(render(dark: dark, view: SettingsView(previewHeight: 1360, tab: .general), h: 1360),
                      to: dir + "/settings-full-\(tag)-\(dark ? "dark" : "light").png")
                write(render(dark: dark, view: SettingsView(previewHeight: 1720, tab: .help), h: 1720),
                      to: dir + "/help-\(tag)-\(dark ? "dark" : "light").png")
            }
        }
        return true
    }

    private static func render(dark: Bool, view rootView: SettingsView, h: CGFloat) -> NSView {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let w: CGFloat = 480, margin: CGFloat = 40
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: w + margin * 2, height: h + margin * 2))
        canvas.wantsLayer = true
        canvas.appearance = appearance

        // 模拟桌面渐变（玻璃透出的背景，便于判断卡片对比度）
        let grad = CAGradientLayer()
        grad.frame = canvas.bounds
        grad.colors = dark
            ? [NSColor(srgbRed: 0.30, green: 0.20, blue: 0.40, alpha: 1).cgColor,
               NSColor(srgbRed: 0.16, green: 0.15, blue: 0.28, alpha: 1).cgColor]
            : [NSColor(srgbRed: 0.80, green: 0.82, blue: 0.96, alpha: 1).cgColor,
               NSColor(srgbRed: 0.94, green: 0.86, blue: 0.90, alpha: 1).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 1, y: 1)
        canvas.layer?.addSublayer(grad)

        let effect = NSVisualEffectView(frame: NSRect(x: margin, y: margin, width: w, height: h))
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.appearance = appearance

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = effect.bounds
        hosting.appearance = appearance
        effect.addSubview(hosting)
        canvas.addSubview(effect)

        canvas.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))   // 让 SwiftUI 完成渲染
        return canvas
    }

    private static func write(_ view: NSView, to path: String) {
        let appearance = view.appearance ?? NSAppearance.currentDrawing()
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
