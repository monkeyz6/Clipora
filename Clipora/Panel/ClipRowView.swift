import AppKit

// MARK: - 设计 Token（对齐「剪贴历史 v2」设计稿，自动深浅色）

enum PanelTheme {
    static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
    /// 随外观切换的动态色
    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }

    static let fg           = dyn(c(29, 29, 31),        c(255, 255, 255, 0.92))
    static let faint        = dyn(c(60, 60, 67, 0.40),  c(255, 255, 255, 0.35))
    static let hoverBg      = dyn(c(255, 255, 255, 0.55), c(255, 255, 255, 0.10))
    static let hoverRing    = dyn(c(255, 255, 255, 0.50), c(255, 255, 255, 0.08))
    static let btnBg        = dyn(c(120, 120, 128, 0.12), c(255, 255, 255, 0.10))
    static let btnFg        = dyn(c(60, 60, 67, 0.60),  c(255, 255, 255, 0.70))
    static let starActive   = c(247, 179, 43)
    static let tabsWrapBg   = dyn(c(120, 120, 128, 0.14), c(255, 255, 255, 0.08))
    static let tabOnBg      = dyn(c(255, 255, 255, 0.90), c(255, 255, 255, 0.18))
    static let tabOnFg      = dyn(c(29, 29, 31),        c(255, 255, 255))
    static let tabOffFg     = dyn(c(60, 60, 67, 0.55),  c(255, 255, 255, 0.45))
    static let chipBg       = dyn(c(255, 255, 255, 0.90), c(255, 255, 255, 0.18))
    static let chipFg       = dyn(c(29, 29, 31),        c(255, 255, 255))
    // 分组胶囊未选中态 / 输入态 / 删除色 / 拖拽落点高亮
    static let chipOffBg    = dyn(c(120, 120, 128, 0.10), c(255, 255, 255, 0.07))
    static let chipOffFg    = dyn(c(60, 60, 67, 0.55),  c(255, 255, 255, 0.50))
    static let chipInputBg  = dyn(c(255, 255, 255, 0.85), c(255, 255, 255, 0.14))
    static let chipDropRing = NSColor.controlAccentColor
    static let destructive  = dyn(c(208, 52, 44),        c(255, 138, 128))
    static let emptyTitle   = dyn(c(60, 60, 67, 0.55),  c(255, 255, 255, 0.60))
    static let topHighlight = dyn(c(255, 255, 255, 0.75), c(255, 255, 255, 0.14))
    static let innerBorder  = dyn(c(255, 255, 255, 0.30), c(255, 255, 255, 0.06))
    static let panelTint    = dyn(c(255, 255, 255, 0.50), c(30, 30, 38, 0.55))

    // 指标
    static let panelWidth: CGFloat = 640
    static let panelRadius: CGFloat = 26
    static let rowHeight: CGFloat = 48
    static let rowGap: CGFloat = 7
    static let rowRadius: CGFloat = 13
    static let listGutter: CGFloat = 12   // 行卡片相对面板边的留白
    static let rowInset: CGFloat = 12     // 行卡片内的内容留白

    /// 可拉伸的圆角遮罩（capInsets），用于把毛玻璃材质裁成圆角/胶囊形状。
    /// 面板与 Toast 共用同一实现，避免遮罩画法各写一份、调整时漏改。
    static func roundedMask(radius: CGFloat) -> NSImage {
        let tile = radius * 2 + 40   // 足够宽的可拉伸中段，避免拉伸边界出现接缝
        let image = NSImage(size: NSSize(width: tile, height: tile), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

// MARK: - 面板边框覆盖层（1px 内描边 + 顶部高光，液态玻璃质感）

/// 覆盖在毛玻璃之上、不拦截点击，只画圆角内描边和顶部高光。用动态色随外观自适应。
final class PanelChromeOverlay: NSView {
    /// 亮边/顶部高光强度倍率，由玻璃风格驱动（1.0 = 标准，不变）
    var chromeScale: CGFloat = 1.0 { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard chromeScale > 0 else { return }   // 强度为 0 时不画描边
        let radius = PanelTheme.panelRadius
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        scaled(PanelTheme.innerBorder).setStroke()
        border.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        let hl = NSBezierPath()
        let y = bounds.maxY - 1   // 顶边（非翻转坐标 maxY 在上）
        hl.move(to: NSPoint(x: radius, y: y))
        hl.line(to: NSPoint(x: bounds.maxX - radius, y: y))
        hl.lineWidth = 1.5
        scaled(PanelTheme.topHighlight).setStroke()
        hl.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 在绘制上下文内解析 dyn 动态色（拿到当前明暗基色），再按 chromeScale 缩放透明度。
    /// 必须在 draw() 内调用；chromeScale==1 时原样返回，保证标准档与旧版逐像素一致。
    private func scaled(_ color: NSColor) -> NSColor {
        guard chromeScale != 1, let resolved = color.usingColorSpace(.sRGB) else { return color }
        return resolved.withAlphaComponent(min(1, resolved.alphaComponent * chromeScale))
    }
}

// MARK: - 面板着色层（叠在毛玻璃之上、内容之下）

/// 用与面板一致的圆角填充一层颜色：nil 不画（纯玻璃）；半透明=暖玻璃着色（如 Cream）；
/// 不透明=纯色背景（纯白/纯黑）。圆角与 effectView 的 maskImage 对齐，四角透明不露方块。
final class PanelTintView: NSView {
    var fillColor: NSColor? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let fillColor else { return }
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: PanelTheme.panelRadius, yRadius: PanelTheme.panelRadius).fill()
    }
}

// MARK: - 圆角玻璃底 + 字形（收藏/删除按钮、已复制 chip 共用）

/// 圆角填充背景 + 居中字形。设 action 即为可点按钮（吞掉事件不冒泡到行）。
final class RoundedGlyphView: NSView {
    var action: (() -> Void)?

    private var text = ""
    private var font: NSFont = .systemFont(ofSize: 13)
    private var fg: NSColor = .labelColor
    private var bg: NSColor = .clear
    private var radius: CGFloat = 9
    var horizontalPadding: CGFloat = 0

    func set(text: String, font: NSFont, fg: NSColor, bg: NSColor, radius: CGFloat) {
        self.text = text; self.font = font; self.fg = fg; self.bg = bg; self.radius = radius
        needsDisplay = true
    }

    /// 仅更新文字（语言切换后刷新已复用 chip 的文案，样式沿用）
    func setText(_ text: String) {
        self.text = text
        needsDisplay = true
    }

    /// 依据文字自适应宽度（chip 用）
    func preferredWidth() -> CGFloat {
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(w) + horizontalPadding * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let size = (text as NSString).size(withAttributes: attrs)
        let p = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: p, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard action != nil else { super.mouseDown(with: event); return }
        // 吞掉，避免冒泡到 NSTableView 触发整行复制
    }
    override func mouseUp(with event: NSEvent) {
        guard let action else { super.mouseUp(with: event); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

// MARK: - 渐变图标徽章（26×26 圆角方块，或缩略图）

final class IconBadgeView: NSView {
    enum Kind { case blue, gray, terminal, green }

    // 徽章渐变是固定常量色，构造 NSGradient 有分配成本，缓存复用（每次绘制不再重建）。
    private static func makeGradient(_ top: NSColor, _ bottom: NSColor) -> NSGradient {
        NSGradient(starting: top, ending: bottom) ?? NSGradient(colors: [top, bottom])!
    }
    private static let blueGradient = makeGradient(PanelTheme.c(91, 155, 255), PanelTheme.c(42, 95, 208))
    private static let greenGradient = makeGradient(PanelTheme.c(78, 203, 113), PanelTheme.c(42, 163, 85))
    private static let grayDarkGradient = makeGradient(PanelTheme.c(58, 61, 70), PanelTheme.c(35, 38, 47))
    private static let grayLightGradient = makeGradient(PanelTheme.c(242, 243, 246), PanelTheme.c(217, 219, 226))

    private var kind: Kind = .gray
    private var symbolName: String?
    private var textGlyph: String?
    private var thumbnail: NSImage?
    private var appIcon: NSImage?

    func set(kind: Kind, symbol: String?, text: String?) {
        self.kind = kind; self.symbolName = symbol; self.textGlyph = text
        self.thumbnail = nil; self.appIcon = nil
        needsDisplay = true
    }

    func setThumbnail(_ image: NSImage) {
        self.thumbnail = image; self.appIcon = nil
        needsDisplay = true
    }

    /// 来源 App 图标（原生形状，直接铺满徽章，不加渐变底）
    func setAppIcon(_ image: NSImage) {
        self.appIcon = image; self.thumbnail = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let rect = bounds
        let clip = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)

        if let appIcon {
            drawAspectFit(appIcon, in: rect)
            return
        }

        if let thumbnail {
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            drawAspectFill(thumbnail, in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        switch kind {
        case .blue:
            Self.blueGradient.draw(in: clip, angle: -45)
        case .green:
            Self.greenGradient.draw(in: clip, angle: -45)
        case .gray:
            (dark ? Self.grayDarkGradient : Self.grayLightGradient).draw(in: clip, angle: -45)
        case .terminal:
            (dark ? PanelTheme.c(12, 14, 18) : PanelTheme.c(35, 38, 47)).setFill()
            clip.fill()
        }

        // 细内描边
        if kind == .gray, !dark {
            strokeRing(rect, PanelTheme.c(0, 0, 0, 0.06))
        } else if kind == .terminal, dark {
            strokeRing(rect, PanelTheme.c(255, 255, 255, 0.08))
        }

        // 字形
        let fg: NSColor
        switch kind {
        case .blue, .green: fg = .white
        case .terminal: fg = PanelTheme.c(124, 227, 139)
        case .gray: fg = dark ? PanelTheme.c(184, 188, 198) : PanelTheme.c(110, 110, 115)
        }
        if let textGlyph {
            drawGlyphText(textGlyph, color: fg, in: rect)
        } else if let symbolName {
            drawSymbol(symbolName, color: fg, in: rect)
        }
    }

    private func strokeRing(_ rect: NSRect, _ color: NSColor) {
        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5)
        ring.lineWidth = 1
        color.setStroke()
        ring.stroke()
    }

    private func drawGlyphText(_ text: String, color: NSColor, in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2),
            withAttributes: attrs
        )
    }

    private func drawSymbol(_ name: String, color: NSColor, in rect: NSRect) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let img = base.tinted(color)
        let size = img.size
        img.draw(in: NSRect(
            x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
            width: size.width, height: size.height
        ))
    }

    private func drawAspectFill(_ image: NSImage, in rect: NSRect) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = max(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    private func drawAspectFit(_ image: NSImage, in rect: NSRect) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = min(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }
}

private extension NSImage {
    /// 模板符号上色副本
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        color.set()
        let r = NSRect(origin: .zero, size: size)
        draw(in: r)
        r.fill(using: .sourceIn)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

// MARK: - 药丸分段控件（历史 / 收藏 N），自绘随外观自适应

final class SegmentedPill: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private var titles: [String]
    private var segments: [RoundedGlyphView] = []
    private static let segFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        for i in titles.indices {
            let seg = RoundedGlyphView()
            seg.action = { [weak self] in self?.select(i, notify: true) }
            addSubview(seg)
            segments.append(seg)
        }
        applyStyles()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String, at index: Int) {
        guard titles.indices.contains(index) else { return }
        titles[index] = title
        applyStyles()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func select(_ index: Int, notify: Bool) {
        guard segments.indices.contains(index) else { return }
        let changed = index != selectedIndex
        selectedIndex = index
        applyStyles()
        if notify, changed { onChange?(index) }
    }

    private func applyStyles() {
        for (i, seg) in segments.enumerated() {
            let on = i == selectedIndex
            seg.set(
                text: titles[i],
                font: .systemFont(ofSize: 13, weight: on ? .semibold : .medium),
                fg: on ? PanelTheme.tabOnFg : PanelTheme.tabOffFg,
                bg: on ? PanelTheme.tabOnBg : .clear,
                radius: 12
            )
        }
    }

    /// 用固定字重量宽，避免选中态字重变化造成宽度抖动
    private func segWidth(_ i: Int) -> CGFloat {
        ceil((titles[i] as NSString).size(withAttributes: [.font: Self.segFont]).width) + 32
    }

    override var intrinsicContentSize: NSSize {
        let w = titles.indices.reduce(CGFloat(0)) { $0 + segWidth($1) }
        return NSSize(width: 6 + w + CGFloat(max(0, segments.count - 1)) * 2, height: 30)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 3
        for (i, seg) in segments.enumerated() {
            let w = segWidth(i)
            seg.frame = NSRect(x: x, y: 3, width: w, height: 24)
            x += w + 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        PanelTheme.tabsWrapBg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

// MARK: - 分组胶囊（收藏页顶部）

/// 单个分组胶囊：点击筛选、双击重命名、右键菜单、可拖拽排序、可作为条目落点。
final class GroupChipView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onDragBegan: ((NSEvent) -> Void)?

    private(set) var groupId: Int64?   // nil = 「全部」
    private var title = ""
    private var active = false
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }
    var draggable = false

    static let height: CGFloat = 26
    private static let font = NSFont.systemFont(ofSize: 12.5)
    private static let activeFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let hPad: CGFloat = 13

    private var mouseDownPoint: NSPoint?

    func configure(groupId: Int64?, title: String, active: Bool, draggable: Bool) {
        self.groupId = groupId
        self.title = title
        self.active = active
        self.draggable = draggable
        toolTip = groupId == nil ? nil : L("双击重命名 · 右键管理", "Double-click to rename · Right-click for options")
        needsDisplay = true
    }

    /// 依据文字与选中态字重自适应宽度
    var fittingWidth: CGFloat {
        let f = active ? Self.activeFont : Self.font
        let w = (title as NSString).size(withAttributes: [.font: f]).width
        return ceil(w) + Self.hPad * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        (active ? PanelTheme.chipBg : PanelTheme.chipOffBg).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if isDropTarget {
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius
            )
            ring.lineWidth = 2
            PanelTheme.chipDropRing.setStroke()
            ring.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: active ? Self.activeFont : Self.font,
            .foregroundColor: active ? PanelTheme.chipFg : PanelTheme.chipOffFg,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }

    // 双击=重命名；单击=筛选；拖拽超阈值=开始排序
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            mouseDownPoint = nil
            onDoubleClick?()
            return
        }
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggable, let start = mouseDownPoint else { return }
        let now = event.locationInWindow
        if abs(now.x - start.x) > 4 || abs(now.y - start.y) > 4 {
            mouseDownPoint = nil
            onDragBegan?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownPoint != nil,
           bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
        mouseDownPoint = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }
}

/// 让单行文本（含编辑时的 field editor）在框里垂直居中，并留出左侧内边距。
/// NSTextField 默认把单行文字顶到框上沿、且贴着左边缘；胶囊标签是居中且带水平留白的，
/// 两者并排会显得输入框文字偏高、贴边。这里统一把绘制/编辑区域垂直居中并左移一段内边距。
final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private static let leftInset: CGFloat = 11   // 与胶囊 hPad(13) 视觉接近

    private func adjusted(_ rect: NSRect) -> NSRect {
        var r = rect
        r.origin.x += Self.leftInset
        r.size.width = max(0, r.size.width - Self.leftInset)
        let textHeight = cellSize(forBounds: r).height
        if textHeight < r.height {
            r.origin.y += (r.height - textHeight) / 2
            r.size.height = textHeight
        }
        return r
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect { super.titleRect(forBounds: adjusted(rect)) }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: adjusted(cellFrame), in: controlView)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: adjusted(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: adjusted(rect), in: controlView, editor: editor, delegate: delegate, start: selStart, length: selLength)
    }
}

/// 收藏页分组胶囊栏：一排可换行的胶囊（全部 / 各分组 / ＋），支持筛选、增删改、拖拽。
final class GroupChipsBar: NSView, NSTextFieldDelegate {

    // 行拖拽落点用（条目 id）；分组自身拖拽排序用（分组 id）
    static let itemDropType = NSPasteboard.PasteboardType("com.clipora.fav-item-id")
    static let chipDragType = NSPasteboard.PasteboardType("com.clipora.group-chip-id")

    var onSelect: ((Int64?) -> Void)?
    var onCreate: ((String) -> Void)?
    var onRename: ((Int64, String) -> Void)?
    var onDelete: ((Int64) -> Void)?
    var onReorder: (([Int64]) -> Void)?
    var onAssignItem: ((Int64, Int64?) -> Void)?     // (条目 id, 目标分组 id；nil=移出分组)
    var onEditingStateChanged: ((Bool) -> Void)?     // 内联编辑起止，供外层挂起键盘流/自动隐藏
    var onMenuWillOpen: (() -> Void)?
    var onMenuDidClose: (() -> Void)?

    private var groups: [ClipGroup] = []
    private var activeGroupId: Int64?
    private var chipViews: [GroupChipView] = []      // [全部, 各分组…]
    private let editField = NSTextField()
    private let editContainer = NSView()   // 非翻转包裹层，见 init 注释
    private let addButton = RoundedGlyphView()
    private var editingGroupId: Int64?
    private var isAdding = false
    private var chipDragId: Int64?
    private var isReceivingDrop = false            // 有拖拽悬停在本栏（行→胶囊 / 胶囊重排）
    private weak var dropTargetChip: GroupChipView?

    private static let fieldWidth: CGFloat = 110
    private static let addButtonWidth: CGFloat = 26
    private static let gap: CGFloat = 6
    private static let lineGap: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        editField.cell = VerticallyCenteredTextFieldCell(textCell: "")   // 文字/光标垂直居中，和胶囊对齐
        // 换成自定义 cell 后必须显式恢复可编辑/可选中：NSTextFieldCell(textCell:) 默认两者皆 false，
        // 会导致 makeFirstResponder 返回 true 却不装 field editor（currentEditor 为 nil）→ 根本打不了字。
        editField.isEditable = true
        editField.isSelectable = true
        editField.isBordered = false
        editField.isBezeled = false
        editField.drawsBackground = false
        editField.usesSingleLineMode = true
        editField.focusRingType = .none
        editField.font = .systemFont(ofSize: 12.5)
        editField.textColor = PanelTheme.fg
        editField.wantsLayer = true
        editField.layer?.cornerRadius = 13
        editField.layer?.cornerCurve = .continuous
        editField.delegate = self
        // 关键：本视图 isFlipped=true（换行布局需要），但把可编辑 NSTextField 直接放进翻转视图里，
        // AppKit 装入的 field editor（实时编辑用的 NSTextView）会在翻转坐标下把 frame 算到 (0,0)，
        // 表现为"编辑时输入框/光标跑到左上角"。所以用一个默认（非翻转）的容器包住 editField，
        // 让 field editor 落在非翻转坐标系里正确定位（这也是同样能正常编辑的搜索框所处的环境）。
        editContainer.isHidden = true
        editContainer.addSubview(editField)
        addSubview(editContainer)

        addButton.set(text: "＋", font: .systemFont(ofSize: 14),
                      fg: PanelTheme.btnFg, bg: PanelTheme.chipOffBg, radius: 13)
        addButton.action = { [weak self] in self?.beginAdd() }
        addButton.toolTip = L("新建分组", "New group")
        addSubview(addButton)

        registerForDraggedTypes([Self.itemDropType, Self.chipDragType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }   // 顶行 y 最小，换行向下

    // MARK: - 数据

    func configure(groups: [ClipGroup], activeGroupId: Int64?) {
        // 编辑/拖拽/有拖拽悬停时不重建，避免打断输入或让落点命中被重建掉的旧胶囊
        guard editingGroupId == nil, !isAdding, chipDragId == nil, !isReceivingDrop else { return }
        self.groups = groups
        self.activeGroupId = activeGroupId
        rebuildChips()
    }

    private func rebuildChips() {
        addButton.toolTip = L("新建分组", "New group")   // 随重建刷新，语言切换后即时更新
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews.removeAll()
        chipViews.append(makeChip(groupId: nil, title: L("全部", "All")))
        for group in groups {
            chipViews.append(makeChip(groupId: group.id, title: group.name))
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func makeChip(groupId: Int64?, title: String) -> GroupChipView {
        let chip = GroupChipView()
        chip.configure(groupId: groupId, title: title,
                       active: activeGroupId == groupId, draggable: groupId != nil)
        chip.onClick = { [weak self] in
            guard let self else { return }
            self.endActiveEditing()   // 先提交进行中的新建/重命名（见下），再切换筛选
            self.onSelect?(groupId)
        }
        chip.onDoubleClick = { [weak self] in
            guard let self, let gid = groupId else { return }
            self.endActiveEditing()
            self.beginRename(groupId: gid, currentName: title)
        }
        chip.onContextMenu = { [weak self, weak chip] event in
            guard let self, let chip, let gid = groupId else { return }
            self.endActiveEditing()
            self.showChipMenu(gid: gid, chip: chip, event: event)
        }
        chip.onDragBegan = { [weak self, weak chip] event in
            guard let self, let chip, let gid = groupId else { return }
            self.endActiveEditing()
            self.beginChipDrag(chip: chip, groupId: gid, event: event)
        }
        addSubview(chip, positioned: .below, relativeTo: editContainer)
        return chip
    }

    // MARK: - 布局（换行排布）

    override func layout() {
        super.layout()
        _ = performLayout(width: bounds.width, apply: true)
    }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 0 ? bounds.width : (PanelTheme.panelWidth - 44)
        return NSSize(width: NSView.noIntrinsicMetric, height: performLayout(width: width, apply: false))
    }

    /// 计算/应用换行布局，返回总高度。apply=false（测量 intrinsicContentSize）时不改任何视图状态。
    @discardableResult
    private func performLayout(width: CGFloat, apply: Bool) -> CGFloat {
        // 组装本次要显示的元素序列：全部 + 各分组（编辑中的替换为输入框）+ 末尾（新建中为输入框）
        var elements: [(view: NSView, width: CGFloat)] = []
        if let all = chipViews.first {
            elements.append((all, all.fittingWidth))
        }
        for (i, group) in groups.enumerated() {
            let chipIndex = i + 1
            guard chipIndex < chipViews.count else { continue }
            if editingGroupId != nil, editingGroupId == group.id {
                elements.append((editContainer, Self.fieldWidth))
            } else {
                elements.append((chipViews[chipIndex], chipViews[chipIndex].fittingWidth))
            }
        }
        elements.append(isAdding ? (editContainer, Self.fieldWidth) : (addButton, Self.addButtonWidth))

        let editing = isAdding || editingGroupId != nil
        if apply {
            // 编辑中的分组胶囊隐藏；输入框仅编辑时显示；末尾按钮仅非新建时显示
            for (i, chip) in chipViews.enumerated() {
                chip.isHidden = i >= 1 && i - 1 < groups.count && groups[i - 1].id == editingGroupId
            }
            editContainer.isHidden = !editing
            addButton.isHidden = isAdding
        }

        let h = GroupChipView.height
        var x: CGFloat = 0, y: CGFloat = 0
        for (view, w) in elements {
            if x > 0, x + w > width {   // 换行
                x = 0
                y += h + Self.lineGap
            }
            if apply {
                view.frame = NSRect(x: x, y: y, width: w, height: h)
            }
            x += w + Self.gap
        }
        if apply, editing {
            editField.frame = editContainer.bounds   // 输入框填满容器（容器已摆到正确槽位）
            effectiveAppearance.performAsCurrentDrawingAppearance {
                editField.layer?.backgroundColor = PanelTheme.chipInputBg.cgColor
            }
        }
        return y + h
    }

    // MARK: - 内联编辑（新建 / 重命名）

    func beginAdd() {
        endActiveEditing()   // 若已有新建/重命名进行中，先提交，避免旧编辑态残留卡死守卫
        isAdding = true
        editingGroupId = nil
        editField.stringValue = ""
        editField.placeholderString = L("分组名", "Group name")
        startEditingUI()
    }

    private func beginRename(groupId: Int64, currentName: String) {
        editingGroupId = groupId
        isAdding = false
        editField.stringValue = currentName
        editField.placeholderString = L("分组名", "Group name")
        startEditingUI()
    }

    private func startEditingUI() {
        onEditingStateChanged?(true)
        invalidateIntrinsicContentSize()
        // 关键：光靠 invalidateIntrinsicContentSize + window.layoutIfNeeded 并不足以让本视图重跑
        // performLayout —— 当分组很少、加上输入框也不换行时，胶囊栏高度不变，Auto Layout 就不会
        // 重新给本视图定 frame，于是 layout()（→ performLayout）根本不被调用，editField 永远停在
        // isHidden=true、frame=0 的初始态。随后 makeFirstResponder 聚焦到这个隐藏零尺寸字段，
        // 下一次显示阶段立刻把它 resignFirstResponder（controlTextDidBeginEditing 都来不及发），
        // 表现为"点＋/重命名毫无反应、名字存不进去"。分组多到换行时高度变了才偶然正常——正是
        // 这个 bug 时有时无的原因。因此必须显式置 needsLayout 并同步跑一次布局，先把 editField
        // 变可见且摆到正确位置，再取焦点，焦点才留得住、用户才能输入。
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.layoutIfNeeded()
        _ = window?.makeFirstResponder(editField)
        editField.currentEditor()?.selectedRange = NSRange(location: editField.stringValue.count, length: 0)
    }

    private func endEditing() {
        isAdding = false
        editingGroupId = nil
        onEditingStateChanged?(false)
        invalidateIntrinsicContentSize()
        // 与 startEditingUI 同理：胶囊栏高度不变时 Auto Layout 不会重跑 layout()，
        // 需显式驱动 performLayout 收起输入框、恢复 ＋ 按钮与被隐藏的胶囊。
        // 否则空名提交（数据层忽略、无变更通知触发重建）后输入框会残留在栏上。
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.layoutIfNeeded()
    }

    private func commitEdit() {
        guard editingGroupId != nil || isAdding else { return }
        let name = editField.stringValue
        let renameId = editingGroupId
        let wasAdding = isAdding
        endEditing()
        if let renameId {
            onRename?(renameId, name)   // 空名在数据层忽略
        } else if wasAdding {
            onCreate?(name)             // 空名在数据层忽略
        }
    }

    private func cancelEdit() {
        guard editingGroupId != nil || isAdding else { return }
        endEditing()
        rebuildChips()
    }

    /// 供外层在切走标签/隐藏面板前收尾正在进行的分组编辑。
    /// 关键：`editField` 只在其 NSTextField 失去 first responder（controlTextDidEndEditing）
    /// 或 Enter/Esc 时才提交，而 GroupChipView / RoundedGlyphView(＋) / HeaderDragView 都没有重写
    /// `acceptsFirstResponder`（默认 false），所以在正在输入分组名时点击别的胶囊/＋/表头
    /// **不会**把 first responder 从输入框抢走 → 不触发 controlTextDidEndEditing → 编辑永远不提交，
    /// `isAdding`/`editingGroupId` 卡死为 true，之后 `configure(...)` 的守卫会永久 early-return，
    /// 胶囊栏再也不刷新（新建/重命名/删除全部"看起来没生效"）。因此每个新交互入口都要先显式提交。
    func endActiveEditing() {
        if editingGroupId != nil || isAdding { commitEdit() }
    }

    /// 硬重置全部内联编辑/拖拽守卫标志（供外层在面板显隐时调用，杜绝跨会话残留导致的冻结）。
    /// 不落库、不触发 onCreate/onRename——纯粹丢弃未提交的编辑态并恢复到干净可刷新状态。
    func resetInteractionState() {
        editingGroupId = nil
        isAdding = false
        chipDragId = nil
        isReceivingDrop = false
        editContainer.isHidden = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === editField else { return }
        if editingGroupId != nil || isAdding { commitEdit() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === editField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitEdit(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEdit(); return true
        default:
            return false
        }
    }

    // MARK: - 右键菜单

    private func showChipMenu(gid: Int64, chip: GroupChipView, event: NSEvent) {
        let menu = NSMenu()
        let rename = NSMenuItem(title: L("重命名", "Rename"), action: #selector(menuRename(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = NSNumber(value: gid)
        menu.addItem(rename)
        let del = NSMenuItem(title: L("删除分组", "Delete group"), action: #selector(menuDelete(_:)), keyEquivalent: "")
        del.target = self
        del.representedObject = NSNumber(value: gid)
        menu.addItem(del)
        onMenuWillOpen?()
        NSMenu.popUpContextMenu(menu, with: event, for: chip)
        onMenuDidClose?()
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let gid = (sender.representedObject as? NSNumber)?.int64Value,
              let name = groups.first(where: { $0.id == gid })?.name else { return }
        beginRename(groupId: gid, currentName: name)
    }

    @objc private func menuDelete(_ sender: NSMenuItem) {
        guard let gid = (sender.representedObject as? NSNumber)?.int64Value else { return }
        onDelete?(gid)
    }

    // MARK: - 分组拖拽排序（chip → chip）

    private func beginChipDrag(chip: GroupChipView, groupId: Int64, event: NSEvent) {
        let pbItem = NSPasteboardItem()
        pbItem.setString(String(groupId), forType: Self.chipDragType)
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        dragItem.setDraggingFrame(chip.frame, contents: chip.snapshotImage())
        chipDragId = groupId
        chip.alphaValue = 0.4
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    // MARK: - 拖拽落点（NSDraggingDestination）

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingDrop = false
        clearDropHighlight()
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        isReceivingDrop = false
        clearDropHighlight()
    }

    private func dragUpdate(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        let relevant = pb.availableType(from: [Self.chipDragType, Self.itemDropType]) != nil
        isReceivingDrop = relevant
        guard relevant else { return [] }
        // 若刚被外部变更重建过，胶囊 frame 可能还是 .zero，先结算布局再命中测试
        layoutSubtreeIfNeeded()
        if pb.availableType(from: [Self.chipDragType]) != nil {
            setDropTarget(nil)   // 分组重排不高亮落点
            return .move
        }
        let point = convert(sender.draggingLocation, from: nil)
        setDropTarget(chipView(at: point))
        return dropTargetChip != nil ? .move : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isReceivingDrop = false
        layoutSubtreeIfNeeded()
        let pb = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)
        defer { clearDropHighlight() }
        if pb.availableType(from: [Self.chipDragType]) != nil,
           let str = pb.string(forType: Self.chipDragType), let draggedId = Int64(str) {
            return reorderChip(draggedId: draggedId, to: point)
        }
        if pb.availableType(from: [Self.itemDropType]) != nil,
           let str = pb.string(forType: Self.itemDropType), let itemId = Int64(str),
           let target = chipView(at: point) {
            onAssignItem?(itemId, target.groupId)   // target.groupId nil = 全部 = 移出分组
            return true
        }
        return false
    }

    private func reorderChip(draggedId: Int64, to point: NSPoint) -> Bool {
        var ids = groups.compactMap { $0.id }
        guard let from = ids.firstIndex(of: draggedId) else { return false }
        let target = groupInsertionIndex(at: point, excluding: draggedId)
        ids.remove(at: from)
        ids.insert(draggedId, at: min(max(target, 0), ids.count))
        onReorder?(ids)
        return true
    }

    /// 落点落在剩余分组胶囊（排除被拖者）中的插入位序（flipped 坐标：y 向下）
    private func groupInsertionIndex(at point: NSPoint, excluding draggedId: Int64) -> Int {
        let remaining = groups.compactMap { $0.id }.filter { $0 != draggedId }
        for (i, gid) in remaining.enumerated() {
            guard let ci = groups.firstIndex(where: { $0.id == gid }) else { continue }
            let frame = chipViews[ci + 1].frame
            if point.y < frame.minY { return i }                          // 落点在更靠上的行
            if point.y <= frame.maxY, point.x < frame.midX { return i }    // 同行且在其左半
        }
        return remaining.count
    }

    // MARK: - 落点高亮

    private func setDropTarget(_ chip: GroupChipView?) {
        guard dropTargetChip !== chip else { return }
        dropTargetChip?.isDropTarget = false
        dropTargetChip = chip
        chip?.isDropTarget = true
    }

    private func clearDropHighlight() { setDropTarget(nil) }

    private func chipView(at point: NSPoint) -> GroupChipView? {
        chipViews.first { !$0.isHidden && $0.frame.contains(point) }
    }
}

extension GroupChipsBar: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        chipDragId = nil
        chipViews.forEach { $0.alphaValue = 1; $0.isDropTarget = false }
        // 未落到有效位（onReorder 未触发 reload）时复原布局
        needsLayout = true
    }
}

private extension NSView {
    /// 用于拖拽的视图快照
    func snapshotImage() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - 行选中/悬停底：圆角卡片 + 内环

final class ClipTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        let rect = bounds.insetBy(dx: PanelTheme.listGutter, dy: 0)
        let path = NSBezierPath(roundedRect: rect, xRadius: PanelTheme.rowRadius, yRadius: PanelTheme.rowRadius)
        PanelTheme.hoverBg.setFill()
        path.fill()
        let ring = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: PanelTheme.rowRadius - 0.5, yRadius: PanelTheme.rowRadius - 0.5
        )
        ring.lineWidth = 1
        PanelTheme.hoverRing.setStroke()
        ring.stroke()
    }
}

// MARK: - 单行：拖拽把手(仅收藏) + 渐变徽章/缩略图 + 单行文本 + 时间 / hover 动作 / 已复制 chip

final class ClipRowCellView: NSTableCellView {

    var onToggleFavorite: (() -> Void)?
    var onDelete: (() -> Void)?
    var onHover: (() -> Void)?
    var onRename: (() -> Void)?
    var onMoveToGroup: (() -> Void)?
    var onCommitAlias: ((String) -> Void)?
    var onCancelAlias: (() -> Void)?

    private let dragHandle = NSTextField(labelWithString: "⠿")
    private let iconBadge = IconBadgeView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let aliasField = NSTextField()
    private let timeLabel = NSTextField(labelWithString: "")
    private let renameButton = RoundedGlyphView()
    private let groupButton = RoundedGlyphView()
    private let starButton = RoundedGlyphView()
    private let deleteButton = RoundedGlyphView()
    private let copiedChip = RoundedGlyphView()

    private var trackingArea: NSTrackingArea?
    /// 键盘上下选择触发 scrollRowToVisible 滚动列表时，光标未动但几何上"路过"了别的行，
    /// inVisibleRect 的 tracking area 会为此误发 mouseEntered，把键盘选中的行顶掉。
    /// 记录指针真实屏幕坐标，滚动导致的进入事件坐标不变，借此和真实移动区分开。
    private static var lastPointerLocation: NSPoint?
    private var showsDragHandle = false
    private var showsGroupButton = false
    private var showsStar = true            // 收藏页不显示收藏(★)按钮（删除即取消收藏）
    private var showsActions = false        // 仅当前选中行为 true（由外层按表格选中状态驱动，而非原始鼠标 hover）
    private var copied = false
    private var isFav = false
    private var isEditingAlias = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        dragHandle.font = .systemFont(ofSize: 13)
        dragHandle.textColor = PanelTheme.faint
        addSubview(dragHandle)

        addSubview(iconBadge)

        titleLabel.font = .systemFont(ofSize: 14.5)
        titleLabel.textColor = PanelTheme.fg
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        addSubview(titleLabel)

        aliasField.isBordered = false
        aliasField.isBezeled = false
        aliasField.drawsBackground = false
        aliasField.focusRingType = .none
        aliasField.font = .systemFont(ofSize: 14.5)
        aliasField.textColor = PanelTheme.fg
        aliasField.delegate = self
        aliasField.wantsLayer = true
        aliasField.layer?.cornerRadius = 8
        aliasField.layer?.cornerCurve = .continuous
        aliasField.isHidden = true
        addSubview(aliasField)

        timeLabel.font = .systemFont(ofSize: 11.5)
        timeLabel.textColor = PanelTheme.faint
        timeLabel.alignment = .right
        addSubview(timeLabel)

        renameButton.action = { [weak self] in self?.onRename?() }
        renameButton.set(text: "✎", font: .systemFont(ofSize: 13, weight: .medium),
                         fg: PanelTheme.btnFg, bg: PanelTheme.btnBg, radius: 9)
        groupButton.action = { [weak self] in self?.onMoveToGroup?() }
        groupButton.set(text: "❏", font: .systemFont(ofSize: 13, weight: .medium),
                        fg: PanelTheme.btnFg, bg: PanelTheme.btnBg, radius: 9)
        starButton.action = { [weak self] in self?.onToggleFavorite?() }
        deleteButton.action = { [weak self] in self?.onDelete?() }
        deleteButton.set(text: "✕", font: .systemFont(ofSize: 13, weight: .medium),
                         fg: PanelTheme.btnFg, bg: PanelTheme.btnBg, radius: 9)
        addSubview(renameButton)
        addSubview(groupButton)
        addSubview(starButton)
        addSubview(deleteButton)

        copiedChip.horizontalPadding = 10
        copiedChip.set(text: L("已复制 ✓", "Copied ✓"), font: .systemFont(ofSize: 12, weight: .semibold),
                       fg: PanelTheme.chipFg, bg: PanelTheme.chipBg, radius: 12)
        copiedChip.isHidden = true
        addSubview(copiedChip)
    }

    // MARK: - 数据绑定

    func configure(with item: ClipItem, showsDragHandle: Bool, showsGroupButton: Bool, showsStar: Bool) {
        self.showsDragHandle = showsDragHandle
        self.showsGroupButton = showsGroupButton
        self.showsStar = showsStar
        showsActions = false   // 绑定后由外层立即按选中状态 setShowsActions 校正
        copied = false
        isEditingAlias = false
        aliasField.isHidden = true
        isFav = item.isFavorite

        // 有别名时按普通字重展示（不再用等宽命令体），并把原文放进 tooltip
        let mono = item.type == .text && item.subtype == .command && item.trimmedAlias == nil
        titleLabel.font = mono
            ? .monospacedSystemFont(ofSize: 13.5, weight: .regular)
            : .systemFont(ofSize: 14.5)
        titleLabel.stringValue = item.resolvedDisplay
        titleLabel.toolTip = item.trimmedAlias != nil ? item.displayText : nil
        timeLabel.stringValue = RelativeTime.string(from: item.createdAt)

        applyStar()
        applyIcon(for: item)
        updateRightZone()
        needsLayout = true
    }

    /// 缩略图由 PanelController 按可见行懒加载后注入
    func showThumbnail(_ image: NSImage) {
        iconBadge.setThumbnail(image)
    }

    private func applyStar() {
        starButton.set(
            text: isFav ? "★" : "☆",
            font: .systemFont(ofSize: 16),
            fg: isFav ? PanelTheme.starActive : PanelTheme.btnFg,
            bg: PanelTheme.btnBg, radius: 9
        )
    }

    private func applyIcon(for item: ClipItem) {
        switch item.type {
        case .image:
            iconBadge.set(kind: .green, symbol: "photo", text: nil)   // 缩略图随后注入
        case .file:
            iconBadge.set(kind: .gray, symbol: "doc.fill", text: nil)
        case .text:
            // 优先显示来源 App 图标；解析不到（旧数据/未安装）再回退子类型徽章
            if let bundle = item.sourceApp, let icon = Self.appIcon(for: bundle) {
                iconBadge.setAppIcon(icon)
                return
            }
            switch item.subtype ?? .plain {
            case .url:     iconBadge.set(kind: .blue, symbol: "link", text: nil)
            case .command: iconBadge.set(kind: .terminal, symbol: nil, text: ">_")
            case .hash:    iconBadge.set(kind: .gray, symbol: "number", text: nil)
            case .plain:   iconBadge.set(kind: .gray, symbol: "text.alignleft", text: nil)
            }
        }
    }

    /// 来源 App 图标缓存（bundle id → 图标）
    private static var appIconCache: [String: NSImage] = [:]
    static func appIcon(for bundleID: String) -> NSImage? {
        if let cached = appIconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIconCache[bundleID] = icon
        return icon
    }

    private func updateRightZone() {
        if isEditingAlias {
            // 编辑别名：隐藏正文与全部右区，仅显示输入框
            titleLabel.isHidden = true
            aliasField.isHidden = false
            copiedChip.isHidden = true
            renameButton.isHidden = true
            groupButton.isHidden = true
            starButton.isHidden = true
            deleteButton.isHidden = true
            timeLabel.isHidden = true
            needsLayout = true
            return
        }
        titleLabel.isHidden = false
        aliasField.isHidden = true
        copiedChip.isHidden = !copied
        if copied { copiedChip.setText(L("已复制 ✓", "Copied ✓")) }   // 复用 cell 语言切换后刷新
        let showActions = showsActions && !copied
        renameButton.isHidden = !showActions
        groupButton.isHidden = !(showActions && showsGroupButton)
        starButton.isHidden = !(showActions && showsStar)
        deleteButton.isHidden = !showActions
        timeLabel.isHidden = showsActions || copied
        needsLayout = true
    }

    // MARK: - 布局（行高 48）

    override func layout() {
        super.layout()
        let h = bounds.height
        let left = PanelTheme.listGutter + PanelTheme.rowInset
        let right = bounds.width - PanelTheme.listGutter - PanelTheme.rowInset
        var x = left

        if showsDragHandle {
            dragHandle.isHidden = false
            dragHandle.sizeToFit()
            dragHandle.frame.origin = NSPoint(x: x, y: (h - dragHandle.frame.height) / 2)
            x += dragHandle.frame.width + 12
        } else {
            dragHandle.isHidden = true
        }

        let iconSize: CGFloat = 26
        iconBadge.frame = NSRect(x: x, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        x += iconSize + 12

        // 右侧动作按钮：从右到左 ✕ [★] [❏] ✎（收藏页无 ★，历史页无 ❏）
        let btn: CGFloat = 30
        let gap: CGFloat = 3
        var bx = right - btn
        deleteButton.frame = NSRect(x: bx, y: (h - btn) / 2, width: btn, height: btn)
        if showsStar {
            bx -= gap + btn
            starButton.frame = NSRect(x: bx, y: (h - btn) / 2, width: btn, height: btn)
        }
        if showsGroupButton {
            bx -= gap + btn
            groupButton.frame = NSRect(x: bx, y: (h - btn) / 2, width: btn, height: btn)
        }
        bx -= gap + btn
        renameButton.frame = NSRect(x: bx, y: (h - btn) / 2, width: btn, height: btn)
        let actionsLeft = bx   // 最左动作按钮（✎）左缘

        timeLabel.sizeToFit()
        timeLabel.frame = NSRect(
            x: right - timeLabel.frame.width, y: (h - timeLabel.frame.height) / 2,
            width: timeLabel.frame.width, height: timeLabel.frame.height
        )

        let chipW = copiedChip.preferredWidth()
        copiedChip.frame = NSRect(x: right - chipW, y: (h - 24) / 2, width: chipW, height: 24)

        let rightBoundary: CGFloat
        if copied { rightBoundary = copiedChip.frame.minX }
        else if showsActions { rightBoundary = actionsLeft }
        else { rightBoundary = timeLabel.frame.minX }

        titleLabel.frame = NSRect(
            x: x, y: (h - 18) / 2, width: max(0, rightBoundary - 8 - x), height: 18
        )
        // 别名输入框：编辑时占据文字区（到右边距全宽）
        aliasField.frame = NSRect(x: x, y: (h - 26) / 2, width: max(0, right - x), height: 26)
    }

    // MARK: - Hover（进入即选中该行，Spotlight 式）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// 鼠标进入即选中该行（Spotlight 式）；动作按钮是否显示交由外层按表格选中状态调用
    /// setShowsActions 统一驱动，避免"哪一行显示按钮"和"哪一行被选中"各自为政。
    override func mouseEntered(with event: NSEvent) {
        guard !isEditingAlias else { return }
        let location = NSEvent.mouseLocation
        // 光标真的没动（滚动导致的几何穿越）就不当作 hover，避免打断键盘选择/滚动。
        if let last = Self.lastPointerLocation, last == location { return }
        Self.lastPointerLocation = location
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {}

    /// 面板每次显示时调用，让首次真实 hover 不被"上次记录的坐标恰好相同"误判为滚动穿越
    static func resetHoverTracking() {
        lastPointerLocation = nil
    }

    /// 由外层依据表格选中行调用：只有当前选中的一行显示动作按钮，从根源避免多行同时显示。
    func setShowsActions(_ show: Bool) {
        guard showsActions != show else { return }
        showsActions = show
        updateRightZone()
    }

    /// 供离屏预览渲染直接置位「显示动作按钮」态（正常运行由表格选中状态驱动）
    func setActionsVisibleForPreview(_ on: Bool) {
        showsActions = on
        updateRightZone()
    }

    // MARK: - 别名内联编辑（重命名，仅改展示）

    func beginAliasEditing(initialText: String, placeholder: String) {
        isEditingAlias = true
        aliasField.stringValue = initialText
        aliasField.placeholderString = placeholder
        updateRightZone()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            aliasField.layer?.backgroundColor = PanelTheme.chipInputBg.cgColor
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(aliasField)
        aliasField.currentEditor()?.selectedRange =
            NSRange(location: aliasField.stringValue.count, length: 0)
    }

    private func endAliasEditing() {
        guard isEditingAlias else { return }
        isEditingAlias = false
        updateRightZone()
    }

    // MARK: - 复制反馈：已复制 chip 浮现

    func flashCopied() {
        showsActions = false
        copied = true
        updateRightZone()
        copiedChip.wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.12
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = -6; move.toValue = 0; move.duration = 0.15
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        copiedChip.layer?.add(fade, forKey: "fade")
        copiedChip.layer?.add(move, forKey: "move")
    }
}

extension ClipRowCellView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        // 失焦（点击面板别处 / 面板隐藏）视为提交；Enter/Esc 已在 doCommandBy 处理并复位
        guard isEditingAlias, obj.object as? NSTextField === aliasField else { return }
        let text = aliasField.stringValue
        endAliasEditing()
        onCommitAlias?(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === aliasField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = aliasField.stringValue
            endAliasEditing()
            onCommitAlias?(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endAliasEditing()
            onCancelAlias?()
            return true
        default:
            return false
        }
    }
}

#if DEBUG
// MARK: - 离屏预览渲染（仅供开发核对视觉，env CLIPORA_PREVIEW_DIR 触发，不参与正常运行）

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 面板玻璃卡片（近似真实 NSVisualEffectView 的半透明底 + 圆角）
private final class PreviewPanelCard: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        PanelTheme.panelTint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: PanelTheme.panelRadius, yRadius: PanelTheme.panelRadius).fill()
    }
}

/// 彩色壁纸背景（近似设计稿）
private final class PreviewWallpaper: NSView {
    var dark = false
    override func draw(_ dirtyRect: NSRect) {
        let g: NSGradient?
        if dark {
            g = NSGradient(colors: [
                PanelTheme.c(46, 40, 78), PanelTheme.c(40, 36, 70), PanelTheme.c(58, 40, 82),
            ])
        } else {
            g = NSGradient(colors: [
                PanelTheme.c(198, 206, 240), PanelTheme.c(206, 190, 235), PanelTheme.c(240, 202, 214),
            ])
        }
        g?.draw(in: bounds, angle: -65)
    }
}

enum PanelPreviewRenderer {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["CLIPORA_PREVIEW_DIR"] else { return false }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let original = AppSettings.language
        defer {
            AppSettings.language = original
            LocalizationManager.shared.language = original
        }
        for (tag, lang) in [("en", AppSettings.Language.en), ("zh", AppSettings.Language.zh)] {
            AppSettings.language = lang
            LocalizationManager.shared.language = lang
            write(render(favorites: false, dark: false), to: dir + "/history-\(tag)-light.png")
            write(render(favorites: false, dark: true), to: dir + "/history-\(tag)-dark.png")
            write(render(favorites: true, dark: false), to: dir + "/favorites-\(tag)-light.png")
            write(render(favorites: true, dark: true), to: dir + "/favorites-\(tag)-dark.png")
        }
        return true
    }

    private static func mk(_ type: ClipType, _ sub: ClipSubtype?, _ content: String,
                           _ ago: TimeInterval, fav: Bool = false, app: String? = nil) -> ClipItem {
        var item = ClipItem(id: nil, type: type, subtype: sub, content: content, thumbnail: nil,
                            imagePath: nil, contentHash: "", isFavorite: fav, favSortOrder: nil,
                            createdAt: Date().addingTimeInterval(-ago))
        item.sourceApp = app
        return item
    }

    private static func historyItems() -> [ClipItem] {
        [
            mk(.image, nil, "", 60),
            mk(.text, .url, "https://github.com/monkeyz6/Clipora", 300, fav: true, app: "com.apple.Safari"),
            mk(.text, .command, "git commit -m \"feat: zero-latency clipboard panel\"", 1500, app: "com.apple.Terminal"),
            mk(.text, .plain, "Ship early, ship often. 🚀", 5400, app: "com.apple.TextEdit"),
            mk(.text, .hash, "550E8400-E29B-41D4-A716-446655440000", 10800, fav: true, app: "com.apple.dt.Xcode"),
            mk(.text, .command, "xcodebuild -scheme Clipora -configuration Release build", 90000),
            mk(.text, .url, "https://developer.apple.com/design/human-interface-guidelines", 96000),
            mk(.text, .plain, "Meeting notes — panel latency budget is 16 ms, favorites never expire.", 180000),
        ]
    }

    /// 图片行的演示缩略图（小风景画，避免依赖磁盘图片）
    private static func demoThumbnail() -> NSImage {
        NSImage(size: NSSize(width: 120, height: 84), flipped: false) { rect in
            NSGradient(colors: [PanelTheme.c(126, 182, 255), PanelTheme.c(206, 168, 255)])!
                .draw(in: rect, angle: 90)
            PanelTheme.c(255, 214, 120).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width * 0.66, y: rect.height * 0.60,
                                        width: 20, height: 20)).fill()
            let hill = NSBezierPath()
            hill.move(to: .zero)
            hill.line(to: NSPoint(x: 0, y: rect.height * 0.34))
            hill.line(to: NSPoint(x: rect.width * 0.38, y: rect.height * 0.70))
            hill.line(to: NSPoint(x: rect.width * 0.62, y: rect.height * 0.28))
            hill.line(to: NSPoint(x: rect.width * 0.82, y: rect.height * 0.48))
            hill.line(to: NSPoint(x: rect.width, y: rect.height * 0.18))
            hill.line(to: NSPoint(x: rect.width, y: 0))
            hill.close()
            PanelTheme.c(88, 146, 112).setFill()
            hill.fill()
            return true
        }
    }

    private static func render(favorites: Bool, dark: Bool) -> NSView {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let panelW = PanelTheme.panelWidth
        let panelH: CGFloat = 500
        let margin: CGFloat = 60
        let canvas = PreviewWallpaper(frame: NSRect(x: 0, y: 0, width: panelW + margin * 2, height: panelH + margin * 2))
        canvas.dark = dark
        canvas.appearance = appearance

        let card = PreviewPanelCard(frame: NSRect(x: margin, y: margin, width: panelW, height: panelH))
        card.wantsLayer = true
        card.layer?.cornerRadius = PanelTheme.panelRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.shadow = {
            let s = NSShadow(); s.shadowBlurRadius = 40
            s.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
            s.shadowOffset = NSSize(width: 0, height: -12); return s
        }()
        canvas.addSubview(card)

        // 顶部：搜索框 + 药丸分段
        let search = NSTextField(labelWithString: "")
        search.font = .systemFont(ofSize: 18)
        search.placeholderAttributedString = NSAttributedString(
            string: favorites ? L("搜索收藏…", "Search favorites…") : L("搜索剪贴历史…", "Search history…"),
            attributes: [.foregroundColor: PanelTheme.faint, .font: NSFont.systemFont(ofSize: 18)])
        search.frame = NSRect(x: 22, y: 19, width: 300, height: 26)
        card.addSubview(search)

        let pill = SegmentedPill(titles: [L("历史", "History"), L("收藏", "Favorites")])
        pill.select(favorites ? 1 : 0, notify: false)
        let pillSize = pill.intrinsicContentSize
        pill.frame = NSRect(x: panelW - 22 - pillSize.width, y: 16, width: pillSize.width, height: pillSize.height)
        card.addSubview(pill)

        // 列表
        let items = favorites ? historyItems().filter(\.isFavorite) : historyItems()
        var y: CGFloat = 60 + 4
        for (i, item) in items.enumerated() {
            let rowView = ClipTableRowView(frame: NSRect(x: 0, y: y, width: panelW, height: PanelTheme.rowHeight))
            let cell = ClipRowCellView(frame: rowView.bounds)
            cell.autoresizingMask = [.width, .height]
            cell.configure(with: item, showsDragHandle: favorites, showsGroupButton: false, showsStar: !favorites)
            if item.type == .image { cell.showThumbnail(demoThumbnail()) }
            if i == 0 {                       // 第一行做「选中/hover」态：卡片高亮 + 动作按钮
                rowView.isSelected = true
                cell.setActionsVisibleForPreview(true)
            } else if !favorites, i == 2 {    // 演示「已复制」chip
                cell.flashCopied()
            }
            rowView.addSubview(cell)
            card.addSubview(rowView)
            y += PanelTheme.rowHeight + PanelTheme.rowGap
        }

        let overlay = PanelChromeOverlay(frame: card.bounds)
        card.addSubview(overlay)

        canvas.appearance = appearance
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
