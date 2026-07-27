import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = PasteboardMonitor()
    private var panelController: PanelController!
    private let hotkeyManager = HotkeyManager()
    private var settingsWindowController: SettingsWindowController?
    private var cleanupTimer: Timer?
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if PanelPreviewRenderer.runIfRequested() || SettingsPreviewRenderer.runIfRequested() {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        #endif
        NSApp.setActivationPolicy(.accessory)  // 无 Dock 图标（配合 LSUIElement）
        AppSettings.registerDefaults()
        AppSettings.applyAppearance()

        panelController = PanelController(monitor: monitor)
        setupStatusItem()
        setupHotkeys()

        monitor.start()
        runAutoCleanup()
        scheduleDailyCleanup()
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Clipora"
            )
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusMenu.delegate = self
        rebuildStatusMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(languageDidChange),
            name: .languageDidChange, object: nil
        )
    }

    /// 按当前语言（重）建状态栏菜单文案。语言切换时重建即时生效。
    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()
        statusMenu.addItem(
            withTitle: L("显示历史", "Show History"),
            action: #selector(showHistoryFromMenu), keyEquivalent: ""
        )
        statusMenu.addItem(
            withTitle: L("显示收藏", "Show Favorites"),
            action: #selector(showFavoritesFromMenu), keyEquivalent: ""
        )
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: L("应用设置", "App Settings"), action: #selector(openSettings), keyEquivalent: ","
        )
        statusMenu.addItem(.separator())
        statusMenu.addItem(
            withTitle: L("退出程序", "Quit"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
    }

    @objc private func languageDidChange() { rebuildStatusMenu() }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // 右键弹菜单：临时挂上 menu 再触发点击，menuDidClose 里摘掉
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
        } else {
            panelController.toggle(tab: .history)
        }
    }

    @objc private func showHistoryFromMenu() {
        panelController.toggle(tab: .history)
    }

    @objc private func showFavoritesFromMenu() {
        panelController.toggle(tab: .favorites)
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 全局快捷键

    private func setupHotkeys() {
        hotkeyManager.bind(
            onHistory: { [weak self] in self?.panelController.toggle(tab: .history) },
            onFavorites: { [weak self] in self?.panelController.toggle(tab: .favorites) }
        )
    }

    // MARK: - 自动清理（启动时 + 每天一次）

    private func runAutoCleanup() {
        guard AppSettings.autoCleanupEnabled else { return }
        DatabaseManager.shared.cleanup(olderThan: AppSettings.retentionDays)
    }

    private func scheduleDailyCleanup() {
        let timer = Timer(timeInterval: 86400, repeats: true) { [weak self] _ in
            self?.runAutoCleanup()
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    /// 维护删除在后台队列执行；退出前先排空，保证「立即清除」等用户确认过的
    /// 操作不会因进程退出被静默回滚，也不遗留已删行的孤儿图片文件。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DatabaseManager.shared.drainMaintenance(timeout: 10) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        // 摘掉 menu，恢复左键点击走 action
        statusItem.menu = nil
    }
}
