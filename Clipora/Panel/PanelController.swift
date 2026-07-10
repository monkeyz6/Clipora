import AppKit

final class PanelController: NSObject {

    enum Tab: Int {
        case history = 0
        case favorites = 1
    }

    private static let panelSize = NSSize(width: PanelTheme.panelWidth, height: 500)
    private static let rowHeight: CGFloat = PanelTheme.rowHeight
    private static let favDragType = NSPasteboard.PasteboardType("com.clipora.fav-row-index")

    private let monitor: PasteboardMonitor
    private let panel: ClipPanel
    private let headerDrag = HeaderDragView()
    private let toast = ToastPresenter()
    private let searchField = NSTextField()
    private let tabs = SegmentedPill(titles: [L("历史", "History"), L("收藏", "Favorites")])
    private let groupChipsBar = GroupChipsBar()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(labelWithString: "")
    private let emptyStack = NSStackView()
    // 玻璃层：存为属性以便运行时按玻璃风格改材质/着色/亮边（在 buildUI 里加进层级）
    private let effectView = NSVisualEffectView()
    private let tintView = PanelTintView()   // 叠在玻璃上、内容下的着色层（Cream/纯白/纯黑）
    private let overlay = PanelChromeOverlay()

    private var items: [ClipItem] = []
    private var groups: [ClipGroup] = []
    private var activeGroupId: Int64?               // nil = 「全部」
    private var currentTab: Tab = .history
    private var keyMonitor: Any?
    private var isClosing = false

    // 收藏页列表顶部随分组栏显隐切换的两条约束
    private var scrollTopHistory: NSLayoutConstraint!
    private var scrollTopFavorites: NSLayoutConstraint!

    // 内联编辑（别名 / 分组名）与菜单期间挂起键盘流、自动隐藏
    private var aliasEditingItemId: Int64?
    private var groupEditing = false
    private var suppressAutoHide = false
    private var isInlineEditing: Bool { aliasEditingItemId != nil || groupEditing }

    /// 「移到分组」菜单项载荷
    private final class GroupPick {
        let itemId: Int64
        let groupId: Int64?
        init(itemId: Int64, groupId: Int64?) { self.itemId = itemId; self.groupId = groupId }
    }

    /// 缩略图按可见行懒加载并缓存，避免全部 BLOB 常驻内存
    private let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// 删除后希望落到的行；由 clipStoreDidChange 驱动的 reload 消费
    private var pendingSelectionRow: Int?
    /// 拖拽排序已用 moveRow 同步 UI，跳过随后一次通知刷新以免打断动画
    private var suppressNextStoreChange = false
    /// 内联编辑期间收到的数据变更挂起，编辑结束后统一刷新，避免拆掉正在编辑的行
    private var pendingReload = false
    /// 用户拖动后的面板左下角位置，仅存内存（程序重启即丢弃，回到默认中间偏上）
    private var savedOrigin: NSPoint?
    /// 程序化移动面板期间置位，避免把 setFrame 误当成用户拖动而记录位置
    private var isProgrammaticMove = false
    /// 拖到默认位置附近的吸附半径
    private static let snapDistance: CGFloat = 44

    init(monitor: PasteboardMonitor) {
        self.monitor = monitor
        panel = ClipPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize))
        super.init()
        buildUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeDidChange),
            name: .clipStoreDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResignKey),
            name: NSWindow.didResignKeyNotification, object: panel
        )
        // 用户拖动时窗口每次移动都记位置（比 performDrag 返回值更可靠，尤其 nonactivating panel）
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(glassStyleDidChange),
            name: .glassStyleDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageDidChange),
            name: .languageDidChange, object: nil
        )
    }

    // MARK: - 玻璃风格

    @objc private func glassStyleDidChange() { applyGlassStyle() }

    // MARK: - 语言切换

    /// 语言切换：分段标题与占位符是在构建期取值、不随 reload 重建的，需显式刷新；
    /// 空态/胶囊/时间等由 reload 重建，可见时顺带刷新，隐藏时下次 show 会自然重载。
    @objc private func languageDidChange() {
        tabs.setTitle(L("历史", "History"), at: Tab.history.rawValue)
        tabs.setTitle(L("收藏", "Favorites"), at: Tab.favorites.rawValue)
        applyPlaceholder(searchPlaceholder(for: currentTab))
        if panel.isVisible, !isInlineEditing { reload() }
    }

    /// 把当前玻璃风格应用到主面板：材质 / 着色层 / 强制外观（文字对比）/ 亮边强度（即时可见）
    private func applyGlassStyle() {
        let style = AppSettings.glassStyle
        effectView.material = style.material
        // 强制外观须每次显式设（含 nil 恢复继承），否则切回玻璃档会残留纯白/纯黑的强制外观
        effectView.appearance = style.forcedAppearance.flatMap { NSAppearance(named: $0) }
        tintView.fillColor = style.tintColor
        overlay.chromeScale = style.chromeScale
    }

    // MARK: - UI 构建

    private func buildUI() {
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        // 圆角遮罩：裁剪毛玻璃材质本身，消除四角露白（仅靠 layer.cornerRadius 无法裁材质）。
        // 只用这一套裁剪——若再叠加 layer.cornerRadius/masksToBounds，两套裁剪各自反走样、
        // 边界毫米级对不齐，会在圆角周围叠出一圈可见的深色细边。
        effectView.maskImage = PanelTheme.roundedMask(radius: PanelTheme.panelRadius)
        effectView.wantsLayer = true

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 18)
        searchField.textColor = PanelTheme.fg
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        applyPlaceholder(searchPlaceholder(for: .history))

        tabs.onChange = { [weak self] index in
            self?.switchTab(to: Tab(rawValue: index) ?? .history)
            self?.reload()
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.setContentHuggingPriority(.required, for: .horizontal)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: PanelTheme.rowGap)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.registerForDraggedTypes([Self.favDragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 14, right: 0)
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyTitle.font = .systemFont(ofSize: 15)
        emptyTitle.textColor = PanelTheme.emptyTitle
        emptyTitle.alignment = .center
        emptyHint.font = .systemFont(ofSize: 13)
        emptyHint.textColor = PanelTheme.faint
        emptyHint.alignment = .center
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 8
        emptyStack.addArrangedSubview(emptyTitle)
        emptyStack.addArrangedSubview(emptyHint)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStack.isHidden = true

        overlay.translatesAutoresizingMaskIntoConstraints = false
        tintView.translatesAutoresizingMaskIntoConstraints = false

        headerDrag.translatesAutoresizingMaskIntoConstraints = false
        headerDrag.onDragEnded = { [weak self] in self?.handleDragEnded() }

        setupGroupChipsBar()
        groupChipsBar.translatesAutoresizingMaskIntoConstraints = false
        groupChipsBar.isHidden = true   // 初始为历史页
        groupChipsBar.setContentHuggingPriority(.defaultHigh, for: .vertical)

        // 着色层置于最底层：盖在玻璃之上、所有内容之下（standard 等纯玻璃档 fillColor=nil 不画）
        effectView.addSubview(tintView)
        // 顶部拖动区：空白处拖动移动面板，搜索框/分段在其上层各自消费点击
        effectView.addSubview(headerDrag)
        effectView.addSubview(searchField)
        effectView.addSubview(tabs)
        effectView.addSubview(groupChipsBar)
        effectView.addSubview(scrollView)
        effectView.addSubview(emptyStack)
        effectView.addSubview(overlay)

        // 列表顶部：历史页贴到 60；收藏页贴到分组栏底部
        scrollTopHistory = scrollView.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 60)
        scrollTopFavorites = scrollView.topAnchor.constraint(equalTo: groupChipsBar.bottomAnchor, constant: 8)
        scrollTopHistory.isActive = true

        NSLayoutConstraint.activate([
            headerDrag.topAnchor.constraint(equalTo: effectView.topAnchor),
            headerDrag.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            headerDrag.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            headerDrag.heightAnchor.constraint(equalToConstant: 60),

            searchField.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 22),
            searchField.centerYAnchor.constraint(equalTo: effectView.topAnchor, constant: 31),
            searchField.trailingAnchor.constraint(lessThanOrEqualTo: tabs.leadingAnchor, constant: -14),

            tabs.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -22),
            tabs.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            groupChipsBar.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 58),
            groupChipsBar.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 22),
            groupChipsBar.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -22),

            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -10),

            emptyStack.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            overlay.topAnchor.constraint(equalTo: effectView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),

            tintView.topAnchor.constraint(equalTo: effectView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])

        panel.contentView = effectView
        applyGlassStyle()   // 统一初始化 material/着色/强制外观/亮边（面板出生即按当前风格）
    }

    /// 装配分组胶囊栏回调（收藏页顶部）
    private func setupGroupChipsBar() {
        groupChipsBar.onSelect = { [weak self] gid in
            guard let self else { return }
            activeGroupId = gid
            reload()
        }
        groupChipsBar.onCreate = { DatabaseManager.shared.createGroup(name: $0) }
        groupChipsBar.onRename = { DatabaseManager.shared.renameGroup(id: $0, name: $1) }
        groupChipsBar.onDelete = { [weak self] id in
            guard let self else { return }
            if activeGroupId == id { activeGroupId = nil }   // 删的是当前筛选分组则回到「全部」
            DatabaseManager.shared.deleteGroup(id: id)
        }
        groupChipsBar.onReorder = { DatabaseManager.shared.updateGroupOrder(ids: $0) }
        groupChipsBar.onAssignItem = { DatabaseManager.shared.setItemGroup(id: $0, groupId: $1) }
        groupChipsBar.onEditingStateChanged = { [weak self] editing in
            guard let self else { return }
            groupEditing = editing
            if !editing {
                restoreSearchFocus()
                if pendingReload, !isInlineEditing { reload() }   // 编辑期间挂起的外部变更补刷
            }
        }
        groupChipsBar.onMenuWillOpen = { [weak self] in self?.suppressAutoHide = true }
        groupChipsBar.onMenuDidClose = { [weak self] in self?.endMenuSuppression() }
    }

    /// 菜单关闭后 didResignKeyNotification 可能延迟到下一轮 runloop 才到达（非激活面板 +
    /// NSMenu 的常见时序坑），提前解除 suppressAutoHide 会让这次迟到的失焦把面板关掉。
    /// 延后一拍再解除，把这个窗口也盖住。
    private func endMenuSuppression() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            suppressAutoHide = false
            reactivatePanelIfNeeded()
        }
    }

    /// 菜单关闭后如面板意外失去 key 状态则重新取回，保证键盘流可用
    private func reactivatePanelIfNeeded() {
        if panel.isVisible, !panel.isKeyWindow { panel.makeKey() }
    }

    /// 搜索框占位文案随当前标签页切换
    private func searchPlaceholder(for tab: Tab) -> String {
        tab == .history ? L("搜索剪贴历史…", "Search history…") : L("搜索收藏…", "Search favorites…")
    }

    /// 占位符用 faint 色，贴合设计
    private func applyPlaceholder(_ text: String) {
        searchField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: PanelTheme.faint, .font: NSFont.systemFont(ofSize: 18)]
        )
    }

    // MARK: - 呼出 / 关闭

    func toggle(tab: Tab) {
        if panel.isVisible {
            hide(animated: false)
        } else {
            show(tab: tab)
        }
    }

    /// 呼出时鼠标所在的屏幕（多屏时面板出现在用户正在用的那块屏）
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    /// 默认位置：指定屏可视区居中、偏上（面板顶部距屏幕顶约 20%，Spotlight 式）
    private func defaultOrigin(on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let topGap = visible.height * 0.20
        let y = visible.maxY - Self.panelSize.height - topGap
        return NSPoint(
            x: visible.midX - Self.panelSize.width / 2,
            y: max(y, visible.minY + 20)          // 屏太矮时兜底不出界
        )
    }

    /// 面板位置：以鼠标所在屏为准。记忆位置若就在该屏则沿用，否则用该屏默认位置。
    private func resolvedOrigin() -> NSPoint {
        let screen = activeScreen()
        if let saved = savedOrigin,
           screen.visibleFrame.intersects(NSRect(origin: saved, size: Self.panelSize)) {
            return saved
        }
        return defaultOrigin(on: screen)
    }

    /// 程序化设置面板位置（不被 panelDidMove 记录）
    private func setPanelOrigin(_ origin: NSPoint) {
        isProgrammaticMove = true
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
        panel.invalidateShadow()   // 换屏/换默认位置后阴影跟着重算，避免残留旧位置的阴影残影
        // setFrame 触发的 didMove 在本轮 runloop 内忽略，用户后续拖动（下一个事件）才记录
        DispatchQueue.main.async { [weak self] in self?.isProgrammaticMove = false }
    }

    /// 窗口移动通知：用户拖动时持续记录位置（程序化移动跳过）
    @objc private func panelDidMove() {
        guard !isProgrammaticMove, panel.isVisible else { return }
        savedOrigin = panel.frame.origin
    }

    /// 拖动结束：靠近所在屏默认位置就吸附回默认并清除记忆，否则保留拖动位置
    private func handleDragEnded() {
        guard panel.isVisible else { return }
        let current = panel.frame.origin
        let def = defaultOrigin(on: panel.screen ?? activeScreen())
        if abs(current.x - def.x) <= Self.snapDistance,
           abs(current.y - def.y) <= Self.snapDistance {
            setPanelOrigin(def)
            savedOrigin = nil                     // 吸附到默认，后续按默认走
        } else {
            savedOrigin = current
        }
    }

    func show(tab: Tab) {
        guard NSScreen.main != nil else { return }
        isClosing = false
        applyGlassStyle()   // 兜底：面板隐藏期间改过设置，下次呼出必用最新玻璃风格
        // 显示前把内联编辑/拖拽守卫态清干净：GroupChipsBar 的标志是进程级、既不随显隐重置，
        // 又只在 first responder 转移时才提交，一旦某次编辑没提交就会永久卡死守卫、冻结整个胶囊栏。
        // 每次显示都硬重置一遍，保证「关掉再打开」必然回到可刷新的干净状态。
        groupEditing = false
        aliasEditingItemId = nil
        pendingReload = false
        groupChipsBar.resetInteractionState()
        switchTab(to: tab)
        searchField.stringValue = ""
        reload()
        ClipRowCellView.resetHoverTracking()

        // 本次运行内拖动过就沿用上次位置，否则回到默认「中间偏上」
        setPanelOrigin(resolvedOrigin())

        // 淡入 + 从 0.96 缩放，≤150ms
        panel.alphaValue = 0
        panel.contentView?.wantsLayer = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        if let layer = panel.contentView?.layer {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = Self.scaledTransform(0.96, size: Self.panelSize)
            scale.toValue = CATransform3DIdentity
            scale.duration = 0.14
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(scale, forKey: "showScale")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        installKeyMonitor()
    }

    func hide(animated: Bool) {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        removeKeyMonitor()

        guard animated, let layer = panel.contentView?.layer else {
            finalizeHide()
            return
        }

        // 面板缩放至 0.96 + 淡出（~150ms）后关闭
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DIdentity
        scale.toValue = Self.scaledTransform(0.96, size: Self.panelSize)
        scale.duration = 0.15
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scale.isRemovedOnCompletion = false
        scale.fillMode = .forwards
        layer.add(scale, forKey: "hideScale")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            layer.removeAnimation(forKey: "hideScale")
            finalizeHide()
        }
    }

    /// 关闭收尾：释放列表数据与缩略图缓存，空闲态常驻内存回落（下次 show 会 reload）
    private func finalizeHide() {
        panel.orderOut(nil)
        panel.alphaValue = 1
        isClosing = false
        items = []
        pendingSelectionRow = nil
        suppressNextStoreChange = false
        aliasEditingItemId = nil
        groupEditing = false
        suppressAutoHide = false
        pendingReload = false
        groupChipsBar.resetInteractionState()
        tableView.reloadData()
        thumbnailCache.removeAllObjects()
    }

    /// 以中心为锚的等效缩放（layer anchor 在左下角，用平移补偿）
    private static func scaledTransform(_ scale: CGFloat, size: NSSize) -> CATransform3D {
        let translate = CATransform3DMakeTranslation(
            size.width * (1 - scale) / 2, size.height * (1 - scale) / 2, 0
        )
        return CATransform3DScale(translate, scale, scale, 1)
    }

    @objc private func panelDidResignKey() {
        // 菜单弹出会短暂让面板失焦，此时不隐藏
        if suppressAutoHide { return }
        // 点到本 App 之外（面板失去 key）：按 Spotlight 惯例关闭面板。若正在内联编辑分组名，
        // 先提交，避免编辑框滞留、也不丢已输入内容（别名字段会在隐藏时自行失焦提交）。
        groupChipsBar.endActiveEditing()
        hide(animated: false)
    }

    // MARK: - 数据加载

    @objc private func storeDidChange() {
        // 拖拽排序已本地同步 UI，跳过这次通知刷新以免打断 moveRow 动画
        if suppressNextStoreChange {
            suppressNextStoreChange = false
            return
        }
        guard panel.isVisible else { return }
        // 内联编辑别名时若立刻 reloadData 会拆掉正在编辑的行（外部剪贴板变更很常见），
        // 挂起到编辑结束后统一刷新
        if isInlineEditing {
            pendingReload = true
            return
        }
        reload()
    }

    private func reload() {
        pendingReload = false
        let query = searchField.stringValue
        let previousSelection = selectedItem()?.id
        let pending = pendingSelectionRow
        pendingSelectionRow = nil

        switch currentTab {
        case .history:
            items = DatabaseManager.shared.history(matching: query)
        case .favorites:
            // 分组栏随收藏刷新；校正失效的 activeGroupId（分组被删）
            groups = DatabaseManager.shared.groups()
            if let gid = activeGroupId, !groups.contains(where: { $0.id == gid }) {
                activeGroupId = nil
            }
            groupChipsBar.configure(groups: groups, activeGroupId: activeGroupId)
            items = DatabaseManager.shared.favorites(matching: query, groupId: activeGroupId)
        }
        tableView.reloadData()
        updateEmptyState(query: query)

        // 删除后落到原位置的相邻行；否则尽量保持原选中项；再否则选第一行（保证纯键盘流可用）
        if let pending, !items.isEmpty {
            let next = min(max(pending, 0), items.count - 1)
            tableView.selectRowIndexes([next], byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
        } else if let previousSelection,
                  let row = items.firstIndex(where: { $0.id == previousSelection }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else if !items.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    private func updateEmptyState(query: String) {
        emptyStack.isHidden = !items.isEmpty
        guard items.isEmpty else { return }
        if currentTab == .favorites {
            if activeGroupId != nil {
                emptyTitle.stringValue = L("这个分组还没有内容", "This group is empty")
                emptyHint.stringValue = L("把收藏条目拖到上方分组胶囊即可归入", "Drag favorites onto the chip above to add them here")
            } else if query.isEmpty {
                emptyTitle.stringValue = L("还没有收藏", "No favorites yet")
                emptyHint.stringValue = L("在历史列表中点 ☆ 即可收藏常用内容", "Click ☆ in the history list to favorite what you use often")
            } else {
                emptyTitle.stringValue = L("没有匹配的收藏", "No matching favorites")
                emptyHint.stringValue = L("试试其他关键词", "Try a different keyword")
            }
        } else if query.isEmpty {
            emptyTitle.stringValue = L("暂无剪贴历史", "No clipboard history")
            emptyHint.stringValue = L("复制任意内容即可在此查看", "Copy anything and it shows up here")
        } else {
            emptyTitle.stringValue = L("没有匹配的记录", "No matching records")
            emptyHint.stringValue = L("试试其他关键词", "Try a different keyword")
        }
    }

    private func selectedItem() -> ClipItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    // MARK: - 标签切换

    private func switchTab(to tab: Tab) {
        // 切走前收尾正在进行的分组内联编辑，避免编辑框滞留在被隐藏的分组栏里卡住键盘流
        groupChipsBar.endActiveEditing()
        currentTab = tab
        tabs.select(tab.rawValue, notify: false)
        applyPlaceholder(searchPlaceholder(for: tab))
        // 收藏页显示分组栏并把列表顶部下移，历史页收起
        let fav = tab == .favorites
        groupChipsBar.isHidden = !fav
        if fav {
            scrollTopHistory.isActive = false
            scrollTopFavorites.isActive = true
        } else {
            scrollTopFavorites.isActive = false
            scrollTopHistory.isActive = true
        }
    }

    // MARK: - 键盘流

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, panel.isKeyWindow else { return event }
            return handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // 内联编辑别名/分组名时，按键交给输入框（Enter/Esc 由其自行处理）
        if isInlineEditing { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53:  // Esc
            hide(animated: true)
            return true
        case 48:  // Tab：历史/收藏切换
            switchTab(to: currentTab == .history ? .favorites : .history)
            reload()
            return true
        case 126:  // ↑
            moveSelection(by: -1)
            return true
        case 125:  // ↓
            moveSelection(by: 1)
            return true
        case 124:  // →：收藏页切到下一个分组；历史页收藏选中项
            if currentTab == .favorites { cycleGroup(by: 1) } else { setFavoriteSelected(true) }
            return true
        case 123:  // ←：收藏页切到上一个分组；历史页取消收藏选中项
            if currentTab == .favorites { cycleGroup(by: -1) } else { setFavoriteSelected(false) }
            return true
        case 36, 76:  // Return / Enter
            copySelectedAndClose()
            return true
        case 51 where flags == .command:  // Cmd+Backspace：删除
            deleteSelected()
            return true
        case 2 where flags == .command:  // Cmd+D：收藏/取消收藏
            toggleFavoriteSelected()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = tableView.selectedRow
        let next = current < 0
            ? (delta > 0 ? 0 : items.count - 1)
            : min(max(current + delta, 0), items.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func deleteSelected() {
        guard let item = selectedItem(), let id = item.id else { return }
        pendingSelectionRow = tableView.selectedRow
        removeItem(id: id)
        // 刷新与选中恢复由 clipStoreDidChange → reload 统一驱动
    }

    /// 收藏页删除 = 移出收藏（历史本体保留，超限时由 FIFO 自然回收）；历史页才真正删除
    private func removeItem(id: Int64) {
        if currentTab == .favorites {
            DatabaseManager.shared.toggleFavorite(id: id)
        } else {
            DatabaseManager.shared.delete(id: id)
        }
    }

    private func toggleFavoriteSelected() {
        guard let item = selectedItem(), let id = item.id else { return }
        favoriteToggle(id: id, willBeFavorite: !item.isFavorite)
    }

    /// →/← 将选中项设为收藏/取消收藏（已是目标态则忽略）
    private func setFavoriteSelected(_ favorite: Bool) {
        guard let item = selectedItem(), let id = item.id, item.isFavorite != favorite else { return }
        favoriteToggle(id: id, willBeFavorite: favorite)
    }

    /// →/← 在「全部 + 各分组」间循环切换筛选（收藏页）；无分组时不动
    private func cycleGroup(by delta: Int) {
        var ids: [Int64?] = [nil]                        // 全部
        ids.append(contentsOf: groups.map(\.id))
        guard ids.count > 1 else { return }
        let current = ids.firstIndex(where: { $0 == activeGroupId }) ?? 0
        activeGroupId = ids[(current + delta + ids.count) % ids.count]
        reload()
    }

    /// 统一收藏切换：写库 + 胶囊 Toast 反馈（面板保持打开）
    private func favoriteToggle(id: Int64, willBeFavorite: Bool) {
        DatabaseManager.shared.toggleFavorite(id: id)
        toast.show(willBeFavorite ? .favorited : .unfavorited, on: panel.screen ?? activeScreen())
    }

    // MARK: - 别名重命名 / 移到分组

    private func beginAliasEdit(item: ClipItem, cell: ClipRowCellView) {
        guard let id = item.id else { return }
        aliasEditingItemId = id
        cell.beginAliasEditing(initialText: item.trimmedAlias ?? "", placeholder: item.displayText)
    }

    private func commitAlias(id: Int64, text: String) {
        // 直接从 A 行切到 B 行编辑时，A 因失焦触发本方法：此时 aliasEditingItemId 已是 B，
        // 只落库 A 的别名，不能清空正在进行的 B 编辑态、也不抢回焦点
        let wasCurrent = aliasEditingItemId == id
        if wasCurrent {
            aliasEditingItemId = nil
            restoreSearchFocus()
        }
        DatabaseManager.shared.setAlias(id: id, alias: text)   // → 通知刷新（编辑中会被挂起）
    }

    private func cancelAlias() {
        aliasEditingItemId = nil
        restoreSearchFocus()
        reload()   // 无数据变更，手动刷新复原展示
    }

    /// 结束内联编辑后异步把焦点交回搜索框（避免在字段回调内同步改 first responder）
    private func restoreSearchFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible else { return }
            panel.makeFirstResponder(searchField)
        }
    }

    private func showMoveToGroupMenu(for item: ClipItem) {
        guard let id = item.id else { return }
        let menu = NSMenu()
        for group in groups {
            guard let gid = group.id else { continue }
            let mi = NSMenuItem(title: group.name, action: #selector(pickGroup(_:)), keyEquivalent: "")
            mi.target = self
            mi.state = (item.groupId == gid) ? .on : .off
            mi.representedObject = GroupPick(itemId: id, groupId: gid)
            menu.addItem(mi)
        }
        if item.groupId != nil {
            menu.addItem(.separator())
            let out = NSMenuItem(title: L("移出分组", "Remove from group"), action: #selector(pickGroup(_:)), keyEquivalent: "")
            out.target = self
            out.representedObject = GroupPick(itemId: id, groupId: nil)
            menu.addItem(out)
        }
        guard let event = NSApp.currentEvent else { return }
        suppressAutoHide = true
        NSMenu.popUpContextMenu(menu, with: event, for: tableView)
        endMenuSuppression()
    }

    @objc private func pickGroup(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? GroupPick else { return }
        DatabaseManager.shared.setItemGroup(id: pick.itemId, groupId: pick.groupId)
    }

    // MARK: - 复制 + 反馈动画 + 关闭

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        copySelectedAndClose()
    }

    private func copySelectedAndClose() {
        guard let item = selectedItem(), !isClosing else { return }
        writeToPasteboard(item)

        // 时序：面板快速缩放淡出关闭(~150ms) → 当前屏幕下方弹出「已复制」胶囊 Toast
        let screen = panel.screen ?? activeScreen()
        hide(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            self?.toast.show(.copied, on: screen)
        }
    }

    private func writeToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.type {
        case .text:
            // 列表行的 content 是截断预览，复制时按 id 取全文回写
            let full = item.id.flatMap { DatabaseManager.shared.fullContent(id: $0) }
            pb.setString(full ?? item.content ?? "", forType: .string)
        case .image:
            if let path = item.imagePath, let data = ImageStore.loadOriginal(path: path) {
                pb.setData(data, forType: .png)
            } else if let id = item.id, let data = DatabaseManager.shared.thumbnail(id: id) {
                pb.setData(data, forType: .png)
            }
        case .file:
            let urls = item.filePaths.map { NSURL(fileURLWithPath: $0) }
            pb.writeObjects(urls)
        }
        // 自身写入不再进历史，避免自我循环
        monitor.markSelfWrite()
    }
}

// MARK: - NSTextFieldDelegate（搜索实时过滤）

extension PanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension PanelController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    /// 选中行变化（鼠标悬停触发的重选，或 ↑/↓ 键盘选择）时，只让新选中行显示动作按钮，
    /// 旧选中行收起——同一时刻表格里最多一行选中，这样从根源保证最多一行显示按钮。
    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = tableView.selectedRow
        // 只更新可见行：离屏行已被回收，滚回可见时 viewFor 会按最新选中态重设动作按钮，
        // 无需在这里扫描全部（可达 2000）行——选中变化由悬停/方向键触发，极高频。
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<visible.upperBound {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? ClipRowCellView else { continue }
            cell.setShowsActions(row == selected)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? ClipTableRowView ?? ClipTableRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < items.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? ClipRowCellView ?? ClipRowCellView()
        cell.identifier = identifier

        let item = items[row]
        let onFav = currentTab == .favorites
        // 收藏页：显示分组按钮、隐藏收藏(★)按钮（删除即取消收藏）；历史页反之
        cell.configure(
            with: item, showsDragHandle: onFav,
            showsGroupButton: onFav && !groups.isEmpty, showsStar: !onFav
        )
        if item.type == .image, let id = item.id, let image = thumbnailImage(for: id) {
            cell.showThumbnail(image)
        }
        // 动作按钮只跟表格的选中行绑定（而非鼠标是否停留在这一行的原始状态）。
        // 否则用键盘上下选择时列表滚动、光标却停在原地不动，会被判定为“鼠标进入了另一行”，
        // 导致多行同时显示按钮；改为由 tableViewSelectionDidChange 统一驱动，天然只有一行。
        cell.setShowsActions(row == tableView.selectedRow)
        // 鼠标悬停即选中该行（Spotlight 式），使选中高亮跟随光标
        cell.onHover = { [weak self, weak cell] in
            guard let self, let cell else { return }
            let hoveredRow = tableView.row(for: cell)
            guard hoveredRow >= 0 else { return }
            tableView.selectRowIndexes([hoveredRow], byExtendingSelection: false)
        }
        // 刷新统一由 clipStoreDidChange 驱动，避免同一操作触发两次全量 reload
        cell.onToggleFavorite = { [weak self] in
            guard let self, let id = item.id else { return }
            favoriteToggle(id: id, willBeFavorite: !item.isFavorite)
        }
        cell.onDelete = { [weak self] in
            guard let self, let id = item.id else { return }
            removeItem(id: id)
        }
        cell.onRename = { [weak self, weak cell] in
            guard let self, let cell else { return }
            beginAliasEdit(item: item, cell: cell)
        }
        cell.onMoveToGroup = { [weak self] in
            self?.showMoveToGroupMenu(for: item)
        }
        cell.onCommitAlias = { [weak self] text in
            guard let self, let id = item.id else { return }
            commitAlias(id: id, text: text)
        }
        cell.onCancelAlias = { [weak self] in self?.cancelAlias() }
        return cell
    }

    /// 可见行按需取缩略图 BLOB 并缓存
    private func thumbnailImage(for id: Int64) -> NSImage? {
        let key = NSNumber(value: id)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let data = DatabaseManager.shared.thumbnail(id: id),
              let image = NSImage(data: data) else { return nil }
        thumbnailCache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    // MARK: 收藏列表拖拽排序

    /// 仅在收藏页、未搜索、且未按分组过滤时允许「表内整体重排」。过滤子集整体重编号
    /// 会破坏未显示收藏项的 fav_sort_order，故此时禁用表内 drop（但仍可拖到分组胶囊）。
    private var canReorderFavorites: Bool {
        currentTab == .favorites && searchField.stringValue.isEmpty && activeGroupId == nil
    }

    /// 收藏页所有行都可拖拽：同时写「行序号」（表内重排用）与「条目 id」（拖到分组胶囊用）
    func tableView(
        _ tableView: NSTableView, pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        guard currentTab == .favorites, row < items.count, let id = items[row].id else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(String(row), forType: Self.favDragType)
        pbItem.setString(String(id), forType: GroupChipsBar.itemDropType)
        return pbItem
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard canReorderFavorites,
              info.draggingSource as? NSTableView === tableView else { return [] }
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard canReorderFavorites,
              let str = info.draggingPasteboard.string(forType: Self.favDragType),
              let sourceRow = Int(str),
              sourceRow >= 0, sourceRow < items.count else { return false }

        var targetRow = row
        if sourceRow < targetRow { targetRow -= 1 }
        guard sourceRow != targetRow else { return false }

        let moved = items.remove(at: sourceRow)
        items.insert(moved, at: targetRow)

        tableView.beginUpdates()
        tableView.moveRow(at: sourceRow, to: targetRow)
        tableView.endUpdates()
        tableView.selectRowIndexes([targetRow], byExtendingSelection: false)

        // moveRow 已同步 UI 与 items，跳过随后通知触发的 reload 以免掐断动画
        suppressNextStoreChange = true
        DatabaseManager.shared.updateFavoriteOrder(ids: items.compactMap(\.id))
        return true
    }
}
